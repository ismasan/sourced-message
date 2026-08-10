# frozen_string_literal: true

require 'plumb'

module Sourced
  class Message
    # Compiles a +[decoder, encoder]+ {Pair} per message class and serializes messages
    # through it. Abstract: a subclass binds the wire format by answering
    # {.default_format}. {JSONCodec} and {FormsCodec} are the two that ship.
    #
    #   codec = Sourced::Message::JSONCodec.default.compile!
    #   codec.encode(message)  # => structures native to the format
    #   codec.decode(attrs)    # => the message
    #
    # Pairs are keyed by type string and built by {#compile!} from a {Registry}; a type
    # missing from the result raises, so a type defined after the compile stays invisible
    # until a fresh codec is built. Compiling is always explicit — nothing here compiles
    # itself on first use — which makes "when is serialization settled?" a question with
    # one answer per process.
    #
    # It encodes the *whole* message, envelope included, which suits a transport carrying
    # a message as a single document (a file, a socket frame, a form submission). A store
    # that keeps the envelope in columns wants only the payload encoded;
    # {Sourced::Store::MessageCodec} subclasses {JSONCodec} for exactly that. The three
    # private seams below are the whole subclass contract:
    #
    #   #compiled_type(klass)           what Plumb type to compile for a message class
    #   #encode_subject(message)        what #encode feeds the encoder
    #   #build(klass, attrs, decoder)   what #decode returns
    #
    # Every subclass gets its own +.default+ and +.pairs+ for free (both are plain class
    # ivars), which is load-bearing: one message class compiles to a different pair under
    # each format and each seam set, and they must not collide.
    class Codec
      # The format a subclass serializes with. Abstract here: {Codec} itself has no
      # format, so it can only be instantiated by passing one explicitly.
      #
      # @return [Class<Plumb::Codec>]
      def self.default_format
        raise NotImplementedError,
              "#{name} has no format of its own; use a subclass (JSONCodec, FormsCodec) " \
              'or pass format:'
      end

      # Raised when a message being written can't be represented in the codec's
      # format, which in practice means the message itself is invalid.
      EncodeError = Class.new(StandardError)

      # Raised when a serialized message no longer satisfies its class's schema —
      # a schema change, a hand-edited record, a foreign writer.
      DecodeError = Class.new(StandardError)

      # Raised when asked for a type this codec has no pair for: one defined after the
      # compile, one absent from this process, or any type at all when nothing has
      # compiled yet.
      UnregisteredTypeError = Class.new(StandardError)

      # A message class's compiled +[decoder, encoder]+ for one format.
      Pair = Data.define(:decoder, :encoder)

      # The instance that callers share. Holding no connections or file handles, it is
      # safe to share, so a process compiles its pairs once.
      #
      # @return [Codec]
      def self.default = @default ||= new

      # Drop the shared instance, so the next {.default} compiles against the current
      # registry — between tests, and for a development-mode class reloader.
      #
      # The {.pairs} cache deliberately survives: building a pair is the expensive part
      # of a compile, and a class that did not change does not need a new one.
      #
      # @return [void]
      def self.reset!
        @default = nil
      end

      # Compiled pairs, keyed by message class, shared across every instance of this
      # class and every reset. A class's schema is fixed once its +define+ block has
      # run, so its pair is too — which makes recompiling a matter of re-collecting
      # existing pairs. Redefining a message type produces a *new* class, so it misses
      # the cache and compiles fresh; that is what makes the cache safe under reloading.
      # (Reopening a class to add attributes after it has been compiled once would not
      # be picked up; {.clear_pairs!} is the way out of that.)
      #
      # Keyed by the message class, not by the type {#compiled_type} returns: a class is
      # identity-keyed and stable, where a Plumb node would put the cache at the mercy
      # of that node's +#hash+/+#eql?+.
      #
      # Held strongly. A weakly-keyed map would not help: a pair is built from its class
      # and refers back to it, so holding the pair keeps the class reachable either way.
      # A reloader that discards classes should call {.clear_pairs!}.
      #
      # @return [Hash{Class => Hash{Class<Plumb::Codec> => Pair}}]
      def self.pairs
        @pairs ||= {}
      end

      # Discard cached pairs, so every class is compiled again. For a reloader dropping
      # classes, and for a class whose schema changed in place — which {.reset!} cannot
      # detect, since the class is the same object.
      #
      # @return [void]
      def self.clear_pairs!
        @pairs = nil
      end

      # @return [Class<Plumb::Codec>] the format compiled onto message types
      attr_reader :format

      # @param format [Class<Plumb::Codec>] the format compiled onto message types.
      #   Defaults to the subclass's {.default_format}; pass one to scope a codec to its
      #   own set of encoders, as specs do.
      # @param registry [Registry] resolves type strings to classes. Needs only +#all+
      #   and +#[]+. Defaults to the root registry, which recurses into every subclass
      #   registry, so one codec covers every message type in the process.
      def initialize(format: self.class.default_format, registry: Sourced::Message.registry)
        @format = format
        @registry = registry
        @messages = nil
      end

      # +attr_reader :format+ shadows +Kernel#format+ in instance scope, so this
      # interpolates.
      #
      # @return [String]
      def inspect = "#<#{self.class.name} format=#{@format.name}#{compiled? ? '' : ' (not compiled)'}>"

      # @return [Boolean] whether {#compile!} has run
      def compiled? = !@messages.nil?

      # Build a pair for every message class in the registry, frozen once they are all in.
      #
      # Also the boot check: a message type this format cannot represent raises here,
      # naming the offending attribute path, so the failure lands at boot instead of on
      # the first message that happens to carry the type.
      #
      # Idempotent, so several collaborators sharing a codec can each call it on start
      # without coordinating. {#recompile!} is how to pick up types registered since.
      #
      # Note what it does *not* check: whether data already written satisfies its schema.
      # That is a per-message question, answered by {#decode} when the message is read.
      #
      # @return [self]
      # @raise [Plumb::TypeError] if any registered message type can't be serialized by
      #   this format
      def compile!
        return self if compiled?

        messages = {}
        @registry.all { |klass| messages[klass.type] = pair_for(klass) }
        @messages = messages.freeze
        self
      end

      # Compile again from scratch, picking up message types and encoders registered
      # since the last compile.
      #
      # @return [self]
      # @raise [Plumb::TypeError] see {#compile!}
      def recompile!
        @messages = nil
        compile!
      end

      # @param type [String] message type string
      # @return [Boolean] whether a pair was compiled for this type
      def registered?(type) = !@messages.nil? && @messages.key?(type)

      # Encode a message into the format's native values, ready to serialize.
      #
      # @param message [Sourced::Message]
      # @return [Object] whatever the format renders — a Hash for JSON
      # @raise [EncodeError] if the message doesn't satisfy its own schema
      # @raise [UnregisteredTypeError] if the type was not compiled
      def encode(message)
        pair(message.type, message.id).encoder.parse(encode_subject(message))
      rescue Plumb::ParseError => e
        raise EncodeError, "cannot encode #{label(message.type, message.id)}: #{e.message}"
      end

      # Rebuild a message from decoded attributes. An unknown type raises: a process
      # reading types it doesn't know about is missing the class.
      #
      # @param attrs [Hash] symbol-keyed message attributes
      # @return [Sourced::Message]
      # @raise [UnknownMessageError] if the type isn't in the registry
      # @raise [UnregisteredTypeError] if the type was not compiled
      # @raise [DecodeError] if the attributes don't satisfy the schema
      def decode(attrs)
        type = attrs[:type]
        klass = @registry[type]
        raise UnknownMessageError, "Unknown message type: #{label(type, attrs[:id])}" unless klass

        build(klass, attrs, pair(type, attrs[:id]).decoder)
      rescue Plumb::ParseError => e
        raise DecodeError, "cannot decode #{label(type, attrs[:id])}: #{e.message}"
      end

      private

      # --- subclass seams -------------------------------------------------------

      # @param klass [Class<Sourced::Message>]
      # @return [Object] the Plumb type to compile a pair for
      def compiled_type(klass) = klass

      # @param message [Sourced::Message]
      # @return [Object] what the encoder receives
      def encode_subject(message) = message

      # @param klass [Class<Sourced::Message>] resolved from the registry
      # @param attrs [Hash] the encoded attributes
      # @param decoder [Object] this type's compiled decoder
      # @return [Sourced::Message]
      def build(_klass, attrs, decoder) = decoder.parse(attrs)

      # --------------------------------------------------------------------------

      # @raise [UnregisteredTypeError] naming the message, and separating "nothing has
      #   compiled" from "this type isn't in the compiled set" — the two are fixed in
      #   different places
      def pair(type, id)
        raise UnregisteredTypeError, "codec has not compiled; #{label(type, id)} cannot be handled" if @messages.nil?

        @messages[type] ||
          raise(UnregisteredTypeError, "no encoder/decoder compiled for #{label(type, id)}")
      end

      # The class's pair for this format, built once per class and reused across every
      # recompile. Building it is the whole cost of a compile — the rewrite walks the
      # schema and resolves an encoder for every leaf.
      def pair_for(klass)
        by_format = self.class.pairs[klass] ||= {}
        by_format[@format] ||= Pair.new(*@format.for(compiled_type(klass)))
      end

      # "orders.placed (a1b2c3…)" — enough to find the offending message.
      def label(type, id) = "#{type} (#{id})"
    end
  end
end

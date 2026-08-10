# frozen_string_literal: true

require 'sourced/message/codec'

module Sourced
  class Message
    # Serializes messages to and from JSON-native structures — Hashes, Arrays, Strings,
    # numbers, booleans, +nil+ — ready for +JSON.dump+. The codec never writes bytes
    # itself, so the transport decides how they are stored or framed.
    #
    #   codec = Sourced::Message::JSONCodec.default.compile!
    #   codec.encode(message)  # => JSON-native Hash
    #   codec.decode(attrs)    # => the message
    #
    # +Plumb::Codec::JSON+ is a process-wide global, so an encoder registered on it
    # teaches every JSON codec in the process at once:
    #
    #   Plumb::Codec::JSON.encoder(MoneyEncoder)
    #
    # Register at load time — a codec compiled before an encoder arrives never sees it.
    #
    # See {Codec} for the machinery, and for the seams a subclass overrides.
    class JSONCodec < Codec
      def self.default_format = Plumb::Codec::JSON
    end
  end
end

# frozen_string_literal: true

require "sourced/message"

# Helpers for codec specs, which compile every type their registry yields.
module CodecSpecHelpers
  # Build a message class without adding it to the global registry.
  #
  # A codec compiles everything its registry hands it, so a type built for one
  # example — especially one deliberately unserializable — must stay out of the
  # registry every other example compiles.
  #
  # @param type_str [String] message type string
  # @param base [Class<Sourced::Message>]
  # @return [Class<Sourced::Message>]
  def self.unregistered_message(type_str, base: Sourced::Event, &payload_block)
    type_str.freeze unless type_str.frozen?

    Class.new(base) do
      def self.node_name = :data
      define_singleton_method(:type) { type_str }
      attribute :type, Sourced::Message::Types::Static[type_str]

      next unless payload_block

      payload_class = Class.new(Sourced::Message::Payload, &payload_block)
      const_set(:Payload, payload_class)
      attribute :payload, payload_class
      names = payload_class._schema.to_h.keys.map(&:to_sym).freeze
      define_singleton_method(:payload_attribute_names) { names }
    end
  end

  # A stand-in for {Sourced::Message::Registry} over a fixed set of classes, so a
  # codec can be scoped to exactly the types an example cares about. These two
  # methods are the whole registry contract a codec depends on.
  class Registry
    def initialize(classes) = @classes = classes
    def all(&block) = @classes.each(&block)
    def [](type) = @classes.find { |klass| klass.type == type }
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

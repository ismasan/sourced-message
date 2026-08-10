# frozen_string_literal: true

require 'json'

RSpec.describe Sourced::Message::JSONCodec do
  # Unregistered, so these types are never compiled by another example's codec.
  let(:rich) do
    CodecSpecHelpers.unregistered_message('codec_spec.rich') do
      attribute :at, Sourced::Message::Types::Time
      attribute :on, Sourced::Message::Types::Date
      attribute :kind, Sourced::Message::Types::Symbol
      attribute :count, Sourced::Message::Types::Integer
    end
  end

  let(:plain) do
    CodecSpecHelpers.unregistered_message('codec_spec.plain') do
      attribute :n, Sourced::Message::Types::Integer
    end
  end

  let(:empty) { CodecSpecHelpers.unregistered_message('codec_spec.empty') }

  # A codec scoped to the given classes, compiled and ready.
  def codec_for(*classes, format: Plumb::Codec::JSON)
    described_class.new(format:, registry: CodecSpecHelpers::Registry.new(classes)).compile!
  end

  let(:codec) { codec_for(rich, plain, empty) }
  let(:message) do
    rich.new(payload: { at: Time.at(1_735_689_600).utc, on: Date.new(2026, 1, 2), kind: :urgent, count: 3 })
  end

  describe '#encode' do
    it 'renders every payload value in the format, not just the envelope' do
      encoded = codec.encode(message)

      expect(encoded[:payload][:at]).to eq('2025-01-01T00:00:00.000000Z')
      expect(encoded[:payload][:on]).to eq('2026-01-02')
      expect(encoded[:payload][:kind]).to eq('urgent')
      expect(encoded[:payload][:count]).to eq(3) # JSON-native, passes through
    end

    it 'renders the envelope too, so the whole message is one native document' do
      encoded = codec.encode(message)

      expect(encoded[:type]).to eq('codec_spec.rich')
      expect(encoded[:id]).to eq(message.id)
      expect(encoded[:created_at]).to be_a(String)
      expect { JSON.generate(encoded) }.not_to raise_error
    end

    it 'raises EncodeError naming the message when it does not satisfy its own schema' do
      # Message.new does not validate, so an invalid message can be built and only
      # fails when something tries to write it.
      invalid = plain.new(payload: { n: nil })

      expect { codec.encode(invalid) }
        .to raise_error(described_class::EncodeError, /codec_spec\.plain \(#{invalid.id}\)/)
    end
  end

  describe '#decode' do
    it 'restores the types the schema declares' do
      decoded = codec.decode(codec.encode(message))

      expect(decoded).to be_a(rich)
      expect(decoded.payload.at).to eq(message.payload.at)
      expect(decoded.payload.on).to eq(Date.new(2026, 1, 2))
      expect(decoded.payload.kind).to eq(:urgent)
      expect(decoded.created_at).to be_a(Time)
    end

    it 'survives a real JSON round trip, which is what a transport does' do
      json = JSON.generate(codec.encode(message))
      decoded = codec.decode(JSON.parse(json, symbolize_names: true))

      expect(decoded.payload.at).to eq(message.payload.at)
      expect(decoded.payload.kind).to eq(:urgent)
    end

    it 'handles a message defined without a payload' do
      expect(codec.decode(codec.encode(empty.new)).type).to eq('codec_spec.empty')
    end

    it 'raises UnknownMessageError for a type this process does not know' do
      expect { codec.decode({ type: 'codec_spec.from_the_future', id: 'abc' }) }
        .to raise_error(Sourced::Message::UnknownMessageError, /codec_spec\.from_the_future/)
    end

    it 'raises DecodeError naming the message when stored values no longer fit the schema' do
      expect { codec.decode({ type: 'codec_spec.plain', id: 'abc', payload: { n: 'not a number' } }) }
        .to raise_error(described_class::DecodeError, /codec_spec\.plain \(abc\)/)
    end
  end

  describe '#compile!' do
    it 'is the boot check: raises for a type this format cannot represent' do
      unrepresentable = CodecSpecHelpers.unregistered_message('codec_spec.unrepresentable') do
        attribute :anything, Plumb::Types::Any
      end

      expect { codec_for(unrepresentable) }.to raise_error(Plumb::TypeError, /anything/)
    end

    it 'reports whether it has been compiled' do
      fresh = described_class.new(registry: CodecSpecHelpers::Registry.new([plain]))
      expect { fresh.compile! }.to change(fresh, :compiled?).from(false).to(true)
    end

    it 'is idempotent, so several collaborators sharing it can each call it' do
      first = codec.encode(message)

      expect { codec.compile! }.not_to change(codec, :compiled?)
      expect(codec.encode(message)).to eq(first)
    end

    it 'registers a pair per known message type' do
      expect(codec.registered?('codec_spec.rich')).to be true
      expect(codec.registered?('codec_spec.nope')).to be false
    end
  end

  describe '#recompile!' do
    it 'picks up a type registered since the last compile' do
      classes = [plain]
      codec = described_class.new(registry: CodecSpecHelpers::Registry.new(classes)).compile!
      expect(codec.registered?('codec_spec.rich')).to be false

      classes << rich
      codec.recompile!

      expect(codec.registered?('codec_spec.rich')).to be true
    end
  end

  describe 'before anything compiles' do
    subject(:codec) { described_class.new(registry: CodecSpecHelpers::Registry.new([plain])) }

    it 'refuses to encode, saying nothing has compiled' do
      expect { codec.encode(plain.new(payload: { n: 1 })) }
        .to raise_error(described_class::UnregisteredTypeError, /has not compiled/)
    end

    it 'refuses to decode, saying nothing has compiled' do
      expect { codec.decode({ type: 'codec_spec.plain', id: 'abc', payload: { n: 1 } }) }
        .to raise_error(described_class::UnregisteredTypeError, /has not compiled/)
    end

    it 'reports nothing as registered' do
      expect(codec.registered?('codec_spec.plain')).to be false
    end
  end

  describe '.default' do
    after { described_class.reset! }

    it 'is the one instance callers share' do
      expect(described_class.default).to be(described_class.default)
    end

    it 'is dropped by reset!, so the next one sees the current registry' do
      first = described_class.default
      described_class.reset!
      expect(described_class.default).not_to be(first)
    end
  end

  describe 'pair caching' do
    def pair_for(klass) = described_class.pairs.dig(klass, Plumb::Codec::JSON)

    it 'reuses a class\'s compiled pair, so recompiling re-collects rather than rebuilds' do
      codec_for(rich)
      first = pair_for(rich)

      codec_for(rich)

      expect(pair_for(rich)).to be(first)
    end

    it 'builds a pair only for a class it has not compiled yet' do
      codec_for(rich)
      before = described_class.pairs.keys

      codec_for(rich, plain)

      expect(described_class.pairs.keys - before).to eq([plain])
    end

    it 'rebuilds from scratch after clear_pairs!, for a schema that changed in place' do
      codec_for(rich)
      first = pair_for(rich)

      described_class.clear_pairs!
      codec_for(rich)

      expect(pair_for(rich)).not_to be(first)
    end
  end
end

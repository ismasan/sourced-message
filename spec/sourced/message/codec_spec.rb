# frozen_string_literal: true

# The abstract base. Its machinery is exercised through the concrete codecs (see
# json_codec_spec.rb); what's left to pin here is the contract between base and
# subclass — which format each one binds, and that they keep their state apart.
RSpec.describe Sourced::Message::Codec do
  let(:plain) do
    CodecSpecHelpers.unregistered_message('codec_base_spec.plain') do
      attribute :n, Sourced::Message::Types::Integer
    end
  end

  let(:registry) { CodecSpecHelpers::Registry.new([plain]) }

  describe 'having no format of its own' do
    it 'refuses to be instantiated without one, naming the subclasses that have one' do
      expect { described_class.new }
        .to raise_error(NotImplementedError, /JSONCodec, FormsCodec|pass format:/)
    end

    it 'is usable directly when handed a format, for a one-off' do
      codec = described_class.new(format: Plumb::Codec::JSON, registry:).compile!
      expect(codec.encode(plain.new(payload: { n: 1 }))[:payload]).to eq(n: 1)
    end
  end

  describe 'the concrete codecs' do
    it 'each bind their own format' do
      expect(Sourced::Message::JSONCodec.default_format).to be(Plumb::Codec::JSON)
      expect(Sourced::Message::FormsCodec.default_format).to be(Plumb::Codec::Forms)
    end

    it 'are both codecs' do
      expect(Sourced::Message::JSONCodec.ancestors).to include(described_class)
      expect(Sourced::Message::FormsCodec.ancestors).to include(described_class)
    end
  end

  describe 'keeping subclass state apart' do
    after do
      Sourced::Message::JSONCodec.reset!
      Sourced::Message::FormsCodec.reset!
    end

    it 'gives each subclass its own shared instance' do
      expect(Sourced::Message::JSONCodec.default).not_to be(Sourced::Message::FormsCodec.default)
    end

    it 'gives each subclass its own pair cache, since one class compiles differently per format' do
      Sourced::Message::JSONCodec.new(registry:).compile!
      Sourced::Message::FormsCodec.new(registry:).compile!

      json_pair = Sourced::Message::JSONCodec.pairs.dig(plain, Plumb::Codec::JSON)
      forms_pair = Sourced::Message::FormsCodec.pairs.dig(plain, Plumb::Codec::Forms)

      expect(json_pair).not_to be_nil
      expect(forms_pair).not_to be_nil
      expect(json_pair).not_to be(forms_pair)
    end
  end
end

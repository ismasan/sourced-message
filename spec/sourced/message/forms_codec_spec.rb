# frozen_string_literal: true

RSpec.describe Sourced::Message::FormsCodec do
  let(:course) do
    CodecSpecHelpers.unregistered_message('forms_codec_spec.course') do
      attribute :course_name, Sourced::Message::Types::String
      attribute :seats, Sourced::Message::Types::Integer
      attribute :starts_on, Sourced::Message::Types::Date
      attribute :published, Sourced::Message::Types::Boolean
    end
  end

  subject(:codec) do
    described_class.new(registry: CodecSpecHelpers::Registry.new([course])).compile!
  end

  let(:message) do
    course.new(payload: { course_name: 'Ruby 101', seats: 30, starts_on: Date.new(2026, 9, 1), published: true })
  end

  it 'uses the Forms format' do
    expect(codec.format).to be(Plumb::Codec::Forms)
  end

  describe '#decode' do
    # The direction that earns its keep: params arrive from a browser as strings and
    # the message's own schema is what types them.
    it 'types string params according to the schema' do
      decoded = codec.decode(
        id: message.id,
        type: 'forms_codec_spec.course',
        created_at: message.created_at.iso8601(6),
        metadata: {},
        payload: { course_name: 'Ruby 101', seats: '30', starts_on: '2026-09-01', published: 'true' }
      )

      expect(decoded.payload.seats).to eq(30)
      expect(decoded.payload.starts_on).to eq(Date.new(2026, 9, 1))
      expect(decoded.payload.published).to be(true)
      expect(decoded.created_at).to be_a(Time)
    end

    it 'raises DecodeError when a param cannot be typed' do
      expect {
        codec.decode(
          id: 'abc', type: 'forms_codec_spec.course', created_at: message.created_at.iso8601(6),
          metadata: {},
          payload: { course_name: 'x', seats: 'not a number', starts_on: '2026-09-01', published: 'true' }
        )
      }.to raise_error(described_class::DecodeError, /forms_codec_spec\.course \(abc\)/)
    end
  end

  describe '#encode' do
    it 'renders every payload scalar as a String, which is what a form carries' do
      payload = codec.encode(message)[:payload]

      expect(payload.values).to all(be_a(String))
      expect(payload[:seats]).to eq('30')
      expect(payload[:starts_on]).to eq('2026-09-01')
    end

    it 'round-trips back to the declared types' do
      decoded = codec.decode(codec.encode(message))

      expect(decoded.payload.seats).to eq(30)
      expect(decoded.payload.starts_on).to eq(Date.new(2026, 9, 1))
      expect(decoded.payload.published).to be(true)
    end
  end
end

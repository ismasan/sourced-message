# frozen_string_literal: true

require 'sourced/message/codec'

module Sourced
  class Message
    # Serializes messages to and from the string-shaped structures of HTML forms and
    # query strings, where every scalar arrives as a String.
    #
    # Decoding is the direction that earns its keep: form params carry no types, so a
    # web handler would otherwise coerce each attribute by hand. Here the message's own
    # schema does it.
    #
    #   codec = Sourced::Message::FormsCodec.default.compile!
    #
    #   codec.decode(
    #     id: '…', type: 'course.created', created_at: '2026-09-01T10:00:00.000000+01:00',
    #     metadata: {}, payload: { course_name: 'Ruby 101', seats: '30', starts_on: '2026-09-01' }
    #   )
    #   # => CourseCreated with seats: 30 (Integer) and starts_on: #<Date: 2026-09-01>
    #
    # Encoding renders the mirror image — every scalar a String — which is what a form
    # needs to round-trip a message back to the browser.
    #
    # See {Codec} for the machinery, and for the seams a subclass overrides.
    class FormsCodec < Codec
      def self.default_format = Plumb::Codec::Forms
    end
  end
end

## [Unreleased]

## [0.2.0]

- Add `Sourced::Message::Codec`, the abstract serializer: it compiles a
  `[decoder, encoder]` pair per registered message type over a `Plumb::Codec` format and
  encodes/decodes whole messages. A subclass binds the format by answering
  `.default_format`; each gets its own `.default` and pair cache.
- Add `Sourced::Message::JSONCodec` (`Plumb::Codec::JSON`) and
  `Sourced::Message::FormsCodec` (`Plumb::Codec::Forms`). The Forms one types string
  params from a browser using the message's own schema.
- Sourced's store and Sidereal's file store and socket pubsub carried near-identical
  copies of this machinery; both now build on it. Three private seams —
  `#compiled_type`, `#encode_subject`, `#build` — let a subclass change what is
  compiled and encoded, which is how `Sourced::Store::MessageCodec` encodes payloads
  alone while keeping its envelope in columns.
- `Sourced::Message::VERSION` is now `0.2.0`.

## [0.1.0] - 2026-06-06

- Initial release

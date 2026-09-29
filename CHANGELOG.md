## [Unreleased]

## [0.4.0]

- Requires plumb 0.4, whose codecs rewrite Hash keys like values: `#encode` now emits
  String keys (`{'type' => ..., 'payload' => {'name' => ...}}`), and decoders accept
  String or Symbol keys. `JSON.dump` output is unchanged.
- `Codec#decode` reads the envelope's `type` and `id` under either key form, so
  `decode(encode(message))` works without a JSON round trip.
- `metadata` is typed as `Types::Metadata`: Symbol keys and `Types::JSONValue` values
  (String, Numeric, boolean, nil, and Arrays/Symbol-keyed Hashes of those, at any depth).
  Codecs now restore nested metadata keys as Symbols. A non-JSON value (a Time, a
  Symbol) makes the message invalid and fails `#encode`, where `JSON.dump` used to
  stringify it silently.
- `Sourced::Message::VERSION` is now `0.4.0`.

## [0.3.0]

- Add `Sourced::Message#correlation_type`, the type counterpart of `correlation_id`:
  the type of the message at the root of a causal chain. `#correlate` now records the
  source's `correlation_type` under `metadata[:correlation_type]` on the target, so
  every consequence of a command carries the command's type. A message that was never
  correlated answers with its own `type`. A target whose metadata already holds a
  `correlation_type` keeps it, which starts a new chain.
- `Sourced::Message::VERSION` is now `0.3.0`.

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

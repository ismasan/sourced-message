# Sourced::Message

`Sourced::Message` is a canonical, typed message class for event-driven Ruby systems. It is the shared base used by [Sourced](https://github.com/ismasan/sourced) and Sidereal, but it has no dependency on either and can be used on its own.

A message is a [Plumb](https://github.com/ismasan/plumb)-typed value object with:

- a stable, human-readable `type` string (e.g. `'course.created'`)
- a typed, validated `payload`
- an auto-generated `id` and `created_at` timestamp
- `causation_id` / `correlation_id` for tracing causal chains across processes
- arbitrary `metadata`
- a global **type registry** that can reconstruct any message from a plain hash — handy for transports, queues and event stores
- **codecs** that serialize messages to JSON or to form params and back, preserving the types each payload declares
- scheduling helpers (`#at` / `#in`) for delayed messages

Messages are immutable: every "mutating" method (`#with_payload`, `#with_metadata`, `#at`, `#correlate`) returns a copy.

## Installation

Install the gem and add it to the application's Gemfile by executing:

```bash
bundle add sourced-message
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install sourced-message
```

Then require it:

```ruby
require 'sourced/message'
```

Requires Ruby >= 3.2.

## Usage

### Defining message types

Use `.define` with a unique type string and an optional block describing the payload attributes (via Plumb's `attribute` DSL):

```ruby
CourseCreated = Sourced::Message.define('course.created') do
  attribute :course_name, String
  attribute :seats, Integer
end
```

Each defined type is a subclass of `Sourced::Message` and is automatically added to the registry.

A message can also be defined with no payload:

```ruby
PingReceived = Sourced::Message.define('ping.received')
```

### Creating messages

Pass the payload as a hash. The payload is validated and coerced against the schema you declared:

```ruby
msg = CourseCreated.new(payload: { course_name: 'Ruby 101', seats: 30 })

msg.id            # => "5f6e..."  (auto-generated UUID)
msg.type          # => "course.created"
msg.created_at    # => 2026-06-06 12:00:00 ... (defaults to Time.now)
msg.metadata      # => {}
msg.causation_id  # => same as msg.id by default
msg.correlation_id # => same as msg.id by default
```

### Reading the payload

The payload is a typed object. Access attributes by method, by `[]`, or with `fetch`:

```ruby
msg.payload.course_name      # => "Ruby 101"
msg.payload[:seats]          # => 30
msg.payload.fetch(:seats)    # => 30
msg.payload.fetch(:missing)  # => raises KeyError
```

### Commands and events

`Sourced::Command` and `Sourced::Event` are ready-made subclasses. Define types on them the same way — they register their own types, all visible from the root registry:

```ruby
EnrollStudent = Sourced::Command.define('student.enroll') do
  attribute :student_id, String
end

StudentEnrolled = Sourced::Event.define('student.enrolled') do
  attribute :student_id, String
end
```

### The registry and `.from`

Every defined type lives in a single registry rooted at `Sourced::Message`. This lets you reconstruct the correct subclass from a plain hash that carries a `:type` key — for example when reading messages off a queue, a database, or an HTTP request:

```ruby
hash = { type: 'course.created', payload: { course_name: 'Ruby 101', seats: 30 } }

msg = Sourced::Message.from(hash)
msg.class        # => CourseCreated
msg.payload.course_name # => "Ruby 101"
```

Resolving from the root `Sourced::Message` finds types registered under any subclass (`Command`, `Event`, or your own):

```ruby
Sourced::Message.from(type: 'student.enroll', payload: { student_id: '42' }).class
# => EnrollStudent

Sourced::Message.from(type: 'unknown.type')
# => raises Sourced::Message::UnknownMessageError
```

Inspect what's registered:

```ruby
Sourced::Message.registry.keys          # => ["course.created", "student.enroll", ...]
Sourced::Message.registry.all.to_a      # => [CourseCreated, EnrollStudent, ...]
Sourced::Message.registry['course.created'] # => CourseCreated
```

### Serialization: codecs

`.from` rebuilds the right class from a hash, but it does **not** translate values. Message types are declared with native Ruby types, and JSON has no `Date`, `Time`, `Symbol` or `BigDecimal` — so a naive `to_h` → JSON → `.from` round trip quietly hands back strings:

```ruby
CourseCreated = Sourced::Message.define('course.created') do
  attribute :course_name, String
  attribute :starts_on, Sourced::Message::Types::Date
  attribute :level, Sourced::Message::Types::Symbol
end

msg = CourseCreated.new(
  payload: { course_name: 'Ruby 101', starts_on: Date.new(2026, 9, 1), level: :beginner }
)

back = Sourced::Message.from(JSON.parse(JSON.dump(msg.to_h), symbolize_names: true))
back.payload.starts_on # => "2026-09-01"  (a String!)
back.payload.level     # => "beginner"    (a String!)
back.valid?            # => false
```

Nothing raises along the way, because `.new` does not validate. The message is simply wrong, and you find out somewhere else entirely.

A codec closes that gap. It compiles a `[decoder, encoder]` pair per registered message type and translates values in both directions. Two ship, differing only in the wire format they bind:

| Class | Format | For |
|---|---|---|
| `Sourced::Message::JSONCodec` | `Plumb::Codec::JSON` | stores, queues, socket frames, files |
| `Sourced::Message::FormsCodec` | `Plumb::Codec::Forms` | HTML form params and query strings |

Both inherit their machinery from `Sourced::Message::Codec`, which is abstract — it has no format of its own and exists to be subclassed (or handed a `format:` for a one-off).

```ruby
codec = Sourced::Message::JSONCodec.default.compile!

encoded = codec.encode(msg)
# => { id: "8f1c…", causation_id: "8f1c…", correlation_id: "8f1c…",
#      created_at: "2026-09-01T10:00:00.000000+01:00", metadata: {}, type: "course.created",
#      payload: { course_name: "Ruby 101", starts_on: "2026-09-01", level: "beginner" } }

decoded = codec.decode(JSON.parse(JSON.dump(encoded), symbolize_names: true))
decoded.payload.starts_on # => #<Date: 2026-09-01>
decoded.payload.level     # => :beginner
```

`#encode` returns JSON-native structures — Hashes, Arrays, Strings, numbers, booleans, `nil` — ready for `JSON.dump`. The codec never writes bytes itself, so the transport decides how they are stored or framed.

#### Compiling is explicit

A codec has no pairs until it is compiled, and it never compiles itself on first use. Compile once, wherever your process considers boot to be over and every message class has loaded:

```ruby
codec = Sourced::Message::JSONCodec.default
codec.compiled?   # => false
codec.compile!    # => the codec, pairs built and frozen
codec.encode(msg) # ready
```

This is also the **boot check**. A message type the format cannot represent raises at `compile!`, naming the offending attribute, instead of failing on the first message that happens to carry it:

```ruby
Sourced::Message.define('reports.generated') { attribute :result, Plumb::Types::Any }
Sourced::Message::JSONCodec.default.compile!
# => Plumb::TypeError: cannot apply Plumb::Codec::JSON[…] (decode) to …:
#    field `payload.result` (Plumb::Types::Any) matches no encoder and is not
#    covered by its noop types. Register an encoder for it, or declare it with .noop.
```

The path is dotted from the message root, so `payload.result` points straight at the attribute to fix.

`#compile!` is **idempotent**, so several collaborators sharing one codec can each call it on start without coordinating. A type registered *after* a compile stays invisible until you ask for a rebuild:

```ruby
codec.compile!    # cheap no-op once compiled
codec.recompile!  # rebuild, picking up types and encoders registered since
```

#### Errors

| Raised by | When |
|---|---|
| `Plumb::TypeError` | `#compile!` — a message type this format cannot represent |
| `JSONCodec::EncodeError` | `#encode` — the message does not satisfy its own schema |
| `JSONCodec::DecodeError` | `#decode` — the encoded values no longer fit the schema (a schema change, a hand-edited record, a foreign writer) |
| `JSONCodec::UnregisteredTypeError` | either — nothing has compiled yet, or this type was not in the compiled set |
| `Sourced::Message::UnknownMessageError` | `#decode` — the type string is not in the registry at all |

`EncodeError` and `DecodeError` name the offending type and message id, so a bad record is findable.

#### Teaching it your own types

The format is `Plumb::Codec::JSON`, a process-wide global. Register an encoder on it and every codec in the process learns the type at once:

```ruby
Money = Data.define(:cents, :currency)

class MoneyEncoder < Plumb::Encoder[
  Plumb::Types::String[/\A-?\d+ [A-Z]{3}\z/] => Plumb::Types::Any[Money]
]
  def encode(money) = "#{money.cents} #{money.currency}"

  def decode(str)
    cents, currency = str.split
    Money.new(cents: cents.to_i, currency:)
  end
end

Plumb::Codec::JSON.encoder(MoneyEncoder)
```

Register at load time. A codec compiled before an encoder arrives never sees it.

Note the constraint this creates: every message class in the registry must be encodable by the format, because `#compile!` walks all of them. A type carrying a value the format knows nothing about fails the compile for everyone.

#### Decoding form params: `FormsCodec`

Form params carry no types — every scalar arrives as a String. `FormsCodec` lets the message's own schema do the coercion a web handler would otherwise do by hand:

```ruby
codec = Sourced::Message::FormsCodec.default.compile!

msg = codec.decode(
  id: SecureRandom.uuid,
  type: 'course.created',
  created_at: Time.now.iso8601(6),
  metadata: {},
  payload: { course_name: 'Ruby 101', seats: '30', starts_on: '2026-09-01' }
)

msg.payload.seats     # => 30                  (Integer, from "30")
msg.payload.starts_on # => #<Date: 2026-09-01> (from "2026-09-01")
```

Encoding renders the mirror image — every scalar a String — which is what a form needs to round-trip a message back to the browser.

#### Encoding something other than the whole message

`JSONCodec` encodes the entire message, envelope included, which suits a transport that carries one message as one document — a file body, a socket frame. A store that keeps the envelope in columns wants only the payload encoded. Subclass and override three private seams:

```ruby
class PayloadOnlyCodec < Sourced::Message::JSONCodec
  private

  # What Plumb type to compile for a message class.
  def compiled_type(klass)
    schema = klass._schema.to_h
    schema[schema.keys.find { |k| k.to_sym == :payload }]
  end

  # What #encode feeds the encoder.
  def encode_subject(message) = message.payload

  # What #decode returns.
  def build(klass, attrs, decoder)
    klass.new(attrs.merge(payload: decoder.parse(attrs[:payload])))
  end
end
```

This is exactly what `Sourced::Store::MessageCodec` does. Subclasses get their own `.default` and pair cache automatically — which they need, since one message class compiles to a different pair on each side.

#### Sharing, resetting and the pair cache

`.default` is the shared instance, so a process compiles its pairs once. `.reset!` drops it — for tests between examples, and for a development-mode class reloader:

```ruby
Sourced::Message::JSONCodec.default   # the shared instance
Sourced::Message::JSONCodec.reset!    # next .default compiles afresh
```

Compiled pairs are cached per message class on the codec class and **survive `reset!`**, because building a pair is the whole cost of a compile and a class that did not change does not need a new one. Redefining a type produces a new class, which misses the cache and compiles fresh. `.clear_pairs!` forces a cold rebuild — needed only for a class whose schema changed *in place*, which `.reset!` cannot detect since the class is the same object.

A codec can also be scoped to its own set of encoders, or to a private registry:

```ruby
class AuditFormat < Plumb::Codec::JSON
  encoder RedactedEmailEncoder
end

Sourced::Message::JSONCodec.new(format: AuditFormat, registry: my_registry).compile!
```

`registry:` needs only `#all(&block)` and `#[](type)` — that is the whole contract.

### Copying with changes

Messages are immutable. Use the `#with_*` helpers to derive new copies:

```ruby
# Merge new metadata (keeps the same id)
tagged = msg.with_metadata(channel: 'web', user_id: '42')
tagged.metadata # => { channel: 'web', user_id: '42' }

# Override payload attributes
updated = msg.with_payload(seats: 25)
updated.payload.seats # => 25
updated.payload.course_name # => "Ruby 101" (unchanged)
```

### Correlation: tracing causal chains

`#correlate` links one message as the cause of another. It returns a copy of the target with `causation_id` set to the source's `id` and `correlation_id` propagated from the source. Metadata from both messages is merged.

```ruby
trigger = EnrollStudent.new(payload: { student_id: '42' })
result  = StudentEnrolled.new(payload: { student_id: '42' })

caused = trigger.correlate(result)
caused.causation_id   # => trigger.id
caused.correlation_id # => trigger.correlation_id
```

This makes it possible to follow a chain of messages across process boundaries: all messages descending from the same originating message share a `correlation_id`, while `causation_id` records the direct parent.

### Scheduling: delayed messages

`#at` (aliased as `#in`) returns a copy with `created_at` set to a future instant. It accepts three forms:

```ruby
# An absolute Time / DateTime
msg.at(Time.now + 3600)

# An Integer number of seconds from now
msg.in(60)

# A Fugit / ISO8601 duration string
msg.in('5m')
msg.in('1h30m')
msg.in('PT1H30M')
```

Scheduling a message into the past raises `Sourced::Message::PastMessageDateError`:

```ruby
msg.at(Time.now - 60) # => raises Sourced::Message::PastMessageDateError
```

Passing a string that isn't a duration (e.g. an absolute date) raises `ArgumentError`:

```ruby
msg.in('2026-12-31T10:00:00') # => raises ArgumentError
```

### Pattern matching with `case`/`when`

`Sourced::Message.===` is transparent to wrappers that implement `#to_message`, so messages match correctly in `case`/`when` even when wrapped (e.g. by a positioned/persisted envelope):

```ruby
case message
when CourseCreated  then handle_course_created(message)
when StudentEnrolled then handle_student_enrolled(message)
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the `VERSION` constant in `lib/sourced/message.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ismasan/sourced-message.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

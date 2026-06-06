# Sourced::Message

`Sourced::Message` is a canonical, typed message class for event-driven Ruby systems. It is the shared base used by [Sourced](https://github.com/ismasan/sourced) and Sidereal, but it has no dependency on either and can be used on its own.

A message is a [Plumb](https://github.com/ismasan/plumb)-typed value object with:

- a stable, human-readable `type` string (e.g. `'course.created'`)
- a typed, validated `payload`
- an auto-generated `id` and `created_at` timestamp
- `causation_id` / `correlation_id` for tracing causal chains across processes
- arbitrary `metadata`
- a global **type registry** that can reconstruct any message from a plain hash — handy for transports, queues and event stores
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

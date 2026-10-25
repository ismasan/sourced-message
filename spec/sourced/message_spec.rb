# frozen_string_literal: true

RSpec.describe Sourced::Message do
  let(:msg_class) do
    Sourced::Message.define('spec.user_created') do
      attribute :name, Plumb::Types::String
      attribute :email, Plumb::Types::String
    end
  end

  let(:bare_class) do
    Sourced::Message.define('spec.bare_event')
  end

  it 'has a version number' do
    expect(Sourced::Message::VERSION).not_to be_nil
  end

  describe '.define' do
    it 'creates a subclass with a fixed type' do
      expect(msg_class.type).to eq('spec.user_created')
    end

    it 'registers the class in the registry' do
      klass = msg_class
      expect(Sourced::Message.registry['spec.user_created']).to eq(klass)
    end

    it 'defines a typed payload class' do
      expect(msg_class.const_get(:Payload).ancestors).to include(Sourced::Message::Payload)
    end

    it 'exposes payload_attribute_names' do
      expect(msg_class.payload_attribute_names).to eq(%i[name email])
    end

    it 'returns empty payload_attribute_names when no block given' do
      expect(bare_class.payload_attribute_names).to eq([])
    end
  end

  describe 'initialization' do
    it 'auto-generates a UUID id' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      expect(msg.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'defaults causation_id and correlation_id to the message id' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      expect(msg.causation_id).to eq(msg.id)
      expect(msg.correlation_id).to eq(msg.id)
    end

    it 'sets the type from the class' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      expect(msg.type).to eq('spec.user_created')
    end

    it 'defaults created_at to now' do
      before = Time.now
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      expect(msg.created_at).to be >= before
    end

    it 'defaults metadata to empty hash' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      expect(msg.metadata).to eq({})
    end

    it 'accepts JSON values in metadata, and nothing else' do
      ok = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' },
                         metadata: { n: 1, flag: false, list: ['a', { b: nil }] })
      expect(ok).to be_valid

      bad = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' }, metadata: { at: Time.now })
      expect(bad).not_to be_valid
      expect(bad.errors[:metadata]).not_to be_nil
    end

    it 'defaults payload to nil when not provided' do
      msg = bare_class.new
      expect(msg.payload).to be_nil
    end
  end

  describe '#payload' do
    let(:msg) { msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' }) }

    it 'exposes payload attributes' do
      expect(msg.payload.name).to eq('Joe')
      expect(msg.payload.email).to eq('joe@example.com')
    end

    it 'supports [] access' do
      expect(msg.payload[:name]).to eq('Joe')
    end

    it 'supports fetch' do
      expect(msg.payload.fetch(:name)).to eq('Joe')
      expect { msg.payload.fetch(:missing) }.to raise_error(KeyError)
    end
  end

  describe '#with_metadata' do
    it 'returns a copy with merged metadata' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      updated = msg.with_metadata(channel: 'ch1', user_id: '42')
      expect(updated.metadata).to eq(channel: 'ch1', user_id: '42')
      expect(updated.id).to eq(msg.id)
    end

    it 'merges into existing metadata' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      updated = msg.with_metadata(a: 1).with_metadata(b: 2)
      expect(updated.metadata).to eq(a: 1, b: 2)
    end

    it 'returns self when given an empty hash' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      expect(msg.with_metadata).to equal(msg)
    end
  end

  describe '#tags' do
    it 'defaults to empty, on defined classes and on Command / Event subclasses' do
      expect(msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' }).tags).to eq({})
      expect(Sourced::Command.define('spec.tags.cmd').new.tags).to eq({})
      expect(Sourced::Event.define('spec.tags.evt').new.tags).to eq({})
    end

    it 'is not part of the payload' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' }).with_tags(order_id: 'o1')
      expect(msg.payload.to_h).to eq(name: 'Joe', email: 'joe@example.com')
    end
  end

  describe '#with_tags' do
    let(:msg) { msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' }) }

    it 'merges tags, stringifying values' do
      tagged = msg.with_tags(order_id: 'o1').with_tags(line: 2)
      expect(tagged.tags).to eq(order_id: 'o1', line: '2')
      expect(tagged.id).to eq(msg.id)
      expect(msg.tags).to eq({})
    end

    it 'returns self when given no tags' do
      expect(msg.with_tags).to equal(msg)
    end

    it 'accepts a tag equal to a payload attribute' do
      expect(msg.with_tags(name: 'Joe').tags).to eq(name: 'Joe')
    end

    it 'raises when a tag names a payload attribute with a different value' do
      expect { msg.with_tags(name: 'Ann') }.to raise_error(Sourced::Message::TagConflictError, /name/)
    end
  end

  describe '#with_payload' do
    it 'returns a copy with merged payload attributes' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      updated = msg.with_payload(email: 'new@example.com')
      expect(updated.payload.email).to eq('new@example.com')
      expect(updated.payload.name).to eq('Joe')
    end
  end

  describe '#correlate' do
    it "keeps the target's tags and copies none of the source's" do
      source = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' }).with_tags(order_id: 'o1')
      target = msg_class.new(payload: { name: 'Ann', email: 'ann@example.com' }).with_tags(line_id: 'l1')
      untagged = msg_class.new(payload: { name: 'Bob', email: 'bob@example.com' })

      expect(source.correlate(target).tags).to eq(line_id: 'l1')
      expect(source.correlate(untagged).tags).to eq({})
    end

    it 'sets causation_id to the source message id' do
      source = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      target = bare_class.new
      correlated = source.correlate(target)
      expect(correlated.causation_id).to eq(source.id)
    end

    it 'propagates correlation_id from the source' do
      source = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      target = bare_class.new
      correlated = source.correlate(target)
      expect(correlated.correlation_id).to eq(source.correlation_id)
    end

    it 'merges metadata from both messages' do
      source = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      source = source.with_metadata(channel: 'ch1')
      target = bare_class.new.with_metadata(request_id: 'abc')
      correlated = source.correlate(target)
      expect(correlated.metadata).to include(channel: 'ch1', request_id: 'abc')
    end

    it 'does not mutate the source message' do
      source = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      target = bare_class.new
      source.correlate(target)
      expect(source.causation_id).to eq(source.id)
    end

    it 'records the correlation type in the target metadata' do
      source = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      target = bare_class.new
      correlated = source.correlate(target)
      expect(correlated.metadata).to include(correlation_type: source.type)
      expect(correlated.correlation_type).to eq(source.type)
    end

    it 'propagates the correlation type down a chain of correlated messages' do
      root = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      child = root.correlate(bare_class.new)
      grandchild = child.correlate(bare_class.new)
      expect(grandchild.correlation_type).to eq(root.type)
      expect(grandchild.causation_id).to eq(child.id)
    end

    it 'lets a target with its own correlation type start a new chain' do
      source = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      target = bare_class.new.with_metadata(correlation_type: 'other.root')
      correlated = source.correlate(target)
      expect(correlated.correlation_type).to eq('other.root')
    end

    it 'preserves the target created_at (does not propagate from source)' do
      future = Time.now + 3600
      source = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' }).at(future)
      target = bare_class.new
      correlated = source.correlate(target)
      expect(correlated.created_at).to eq(target.created_at)
      expect(correlated.created_at).not_to eq(source.created_at)
    end
  end

  describe '#correlation_type' do
    it 'is the message own type when not correlated' do
      msg = msg_class.new(payload: { name: 'Joe', email: 'joe@example.com' })
      expect(msg.correlation_type).to eq(msg.type)
    end

    it 'reads an explicitly set correlation type from metadata' do
      msg = bare_class.new.with_metadata(correlation_type: 'explicit.root')
      expect(msg.correlation_type).to eq('explicit.root')
    end
  end

  describe '#at' do
    it 'returns a copy with created_at set to the given time' do
      msg = bare_class.new
      future = Time.now + 60
      delayed = msg.at(future)
      expect(delayed.created_at).to eq(future)
      expect(delayed.id).to eq(msg.id)
    end

    it 'raises when given a time in the past' do
      msg = bare_class.new
      expect { msg.at(Time.now - 60) }.to raise_error(Sourced::Message::PastMessageDateError)
    end

    it 'accepts an Integer as seconds added to Time.now' do
      msg = bare_class.new
      before = Time.now
      delayed = msg.at(60)
      after = Time.now

      expect(delayed.created_at).to be_within(1).of(before + 60)
      expect(delayed.created_at).to be <= after + 60
    end

    it 'raises when given a negative Integer that resolves before created_at' do
      msg = bare_class.new
      expect { msg.at(-3600) }.to raise_error(Sourced::Message::PastMessageDateError)
    end

    it 'accepts a Fugit duration String added to Time.now' do
      msg = bare_class.new
      before = Time.now
      delayed = msg.at('5m')
      expect(delayed.created_at).to be_within(1).of(before + 5 * 60)
    end

    it 'accepts an ISO8601 duration String' do
      msg = bare_class.new
      before = Time.now
      delayed = msg.at('PT1H30M')
      expect(delayed.created_at).to be_within(1).of(before + 90 * 60)
    end

    it 'adds a duration String in the hour the clocks go back' do
      tz = ENV['TZ']
      ENV['TZ'] = 'Europe/London'
      # 01:30 BST, which happens again an hour later as 01:30 GMT.
      now = Time.utc(2026, 10, 25, 0, 30).getlocal
      allow(Time).to receive(:now).and_return(now)

      delayed = bare_class.new.at('1h30m')
      expect(delayed.created_at).to eq(now + 90 * 60)
    ensure
      ENV['TZ'] = tz
    end

    it 'raises ArgumentError for a duration in months or years' do
      msg = bare_class.new
      %w[1M P1M 1y P1Y1D].each do |value|
        expect { msg.at(value) }.to raise_error(ArgumentError, /can't delay by months or years/)
      end
    end

    it 'raises ArgumentError when the String is not a duration (e.g. a date)' do
      msg = bare_class.new
      expect {
        msg.at('2026-12-31T10:00:00')
      }.to raise_error(ArgumentError, /must be an ISO8601 \/ Fugit duration/)
    end

    it 'aliases #in to #at' do
      msg = bare_class.new
      before = Time.now
      delayed = msg.in(60)
      expect(delayed.created_at).to be_within(1).of(before + 60)
    end
  end

  describe '.from' do
    it 'instantiates the correct subclass from a type string' do
      klass = msg_class # ensure registered
      msg = Sourced::Message.from(type: 'spec.user_created', payload: { name: 'Joe', email: 'joe@example.com' })
      expect(msg).to be_a(klass)
      expect(msg.payload.name).to eq('Joe')
    end

    it 'raises for unknown type strings' do
      expect {
        Sourced::Message.from(type: 'spec.nonexistent')
      }.to raise_error(Sourced::Message::UnknownMessageError)
    end

    it 'resolves types registered under subclasses from the root' do
      cmd_class = Sourced::Command.define('spec.do_thing')
      evt_class = Sourced::Event.define('spec.thing_done')

      expect(Sourced::Message.from(type: 'spec.do_thing')).to be_a(cmd_class)
      expect(Sourced::Message.from(type: 'spec.thing_done')).to be_a(evt_class)
    end
  end

  describe 'Registry' do
    it '#all enumerates all registered classes' do
      klass = msg_class # ensure registered
      all = Sourced::Message.registry.all.to_a
      expect(all).to include(klass)
    end

    it '#keys lists registered type strings' do
      msg_class # ensure registered
      expect(Sourced::Message.registry.keys).to include('spec.user_created')
    end

    describe 'registering a type again' do
      let(:root) { Class.new(Sourced::Message) }
      let(:registry) { root.registry }

      def named(const, klass)
        stub_const("RegistrySpec::#{const}", klass)
      end

      it 'raises on lookup once a differently named class holds the type' do
        named(:Foo, root.define('spec.registry.dup'))
        named(:Bar, root.define('spec.registry.dup'))

        expect { registry['spec.registry.dup'] }.to raise_error(
          Sourced::Message::DuplicateTypeError,
          'message type "spec.registry.dup" is claimed by both RegistrySpec::Foo and RegistrySpec::Bar'
        )
      end

      it 'raises from #all' do
        named(:Foo, root.define('spec.registry.dup'))
        named(:Bar, root.define('spec.registry.dup'))

        expect { registry.all.to_a }.to raise_error(Sourced::Message::DuplicateTypeError)
      end

      it 'raises from the root registry' do
        named(:Foo, root.define('spec.registry.dup'))
        named(:Bar, root.define('spec.registry.dup'))

        expect { Sourced::Message.registry['spec.registry.dup'] }.to raise_error(Sourced::Message::DuplicateTypeError)
      end

      it 'raises on the next registration of the type' do
        named(:Foo, root.define('spec.registry.dup'))
        named(:Bar, root.define('spec.registry.dup'))

        expect { root.define('spec.registry.dup') }.to raise_error(Sourced::Message::DuplicateTypeError)
      end

      it 'raises right away for a named class, keeping the registered one' do
        foo = named(:Foo, root.define('spec.registry.dup'))
        bar = named(:Bar, Class.new(root))

        expect { registry['spec.registry.dup'] = bar }.to raise_error(Sourced::Message::DuplicateTypeError)
        expect(registry['spec.registry.dup']).to equal(foo)
      end

      it 'raises past anonymous classes registered in between' do
        named(:Foo, root.define('spec.registry.dup'))
        root.define('spec.registry.dup')
        named(:Bar, root.define('spec.registry.dup'))

        expect { registry['spec.registry.dup'] }.to raise_error(Sourced::Message::DuplicateTypeError)
      end

      it 'replaces a class redefined under the same name, as a reloader does' do
        named(:Foo, root.define('spec.registry.dup'))
        reloaded = named(:Foo, root.define('spec.registry.dup'))

        expect(registry['spec.registry.dup']).to equal(reloaded)
      end

      it 'replaces an anonymous class' do
        root.define('spec.registry.dup')
        foo = named(:Foo, root.define('spec.registry.dup'))

        expect(registry['spec.registry.dup']).to equal(foo)
      end

      it 'treats a constant in an anonymous module as anonymous until the module is named' do
        named(:Foo, root.define('spec.registry.dup'))
        namespace = Module.new
        namespace.const_set(:Bar, root.define('spec.registry.dup'))

        expect(registry['spec.registry.dup']).to equal(namespace::Bar)

        named(:Namespace, namespace)
        expect { registry['spec.registry.dup'] }.to raise_error(
          Sourced::Message::DuplicateTypeError, /RegistrySpec::Foo and RegistrySpec::Namespace::Bar/
        )
      end

      it 'is replaced by an anonymous class' do
        named(:Foo, root.define('spec.registry.dup'))
        anonymous = root.define('spec.registry.dup')

        expect(registry['spec.registry.dup']).to equal(anonymous)
        expect(registry.all.to_a).to eq([anonymous])
      end
    end
  end

  describe 'Command and Event' do
    it 'are message subclasses' do
      expect(Sourced::Command.ancestors).to include(Sourced::Message)
      expect(Sourced::Event.ancestors).to include(Sourced::Message)
    end

    it 'register their own types, visible from the root registry' do
      cmd = Sourced::Command.define('spec.command_x')
      expect(Sourced::Command.registry['spec.command_x']).to eq(cmd)
      expect(Sourced::Message.registry['spec.command_x']).to eq(cmd)
    end
  end

  describe '#to_message and .===' do
    it '#to_message returns self' do
      msg = bare_class.new
      expect(msg.to_message).to equal(msg)
    end

    it 'matches direct instances via case/when' do
      msg = bare_class.new
      expect(Sourced::Message === msg).to be(true)
      expect(bare_class === msg).to be(true)
    end

    it 'unwraps objects implementing #to_message' do
      msg = bare_class.new
      wrapper = Struct.new(:to_message).new(msg)
      expect(bare_class === wrapper).to be(true)
    end

    it 'returns false for non-messages without #to_message' do
      expect(Sourced::Message === Object.new).to be(false)
    end
  end
end

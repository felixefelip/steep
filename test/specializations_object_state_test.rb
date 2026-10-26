require_relative "test_helper"
require_relative "specializations_project_helper"

# An options hash kept in an object's state on its way to the method that
# branches on it, as Active Record's reflections keep theirs
# (felixefelip/steep#298, #301), read back by an ordinary check.
class SpecializationsObjectStateTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def test_a_hash_kept_in_an_object_reads_back_its_branch
    in_tmpdir do
      write("sig/pick.rbs", <<~RBS)
        class P8Plain
        end
        class P8Through
        end
        class P8Reflection
          @options: Hash[Symbol, untyped]
          attr_reader options: Hash[Symbol, untyped]
          def initialize: (Hash[Symbol, untyped] options) -> void
          def kind: () -> (singleton(P8Through) | singleton(P8Plain))
        end
        class P8Picker
          def self.pick: (P8Reflection reflection) -> (singleton(P8Through) | singleton(P8Plain))
        end
        class P8Builder
          def self.stored: (Hash[Symbol, untyped] options) -> P8Reflection
          def self.keywords: (**untyped) -> P8Reflection
        end
        class P8Use
          def a_through: () -> untyped
          def a_plain: () -> untyped
          def b_through: () -> untyped
          def b_plain: () -> untyped
          def c_through: () -> untyped
          def c_plain: () -> untyped
          def d_through: () -> untyped
          def d_plain: () -> untyped
        end
      RBS
      write("app/pick.rb", <<~RUBY)
        class P8Reflection
          attr_reader :options

          def initialize(options)
            @options = options
          end

          def kind
            options[:through] ? P8Through : P8Plain
          end
        end

        class P8Picker
          def self.pick(reflection)
            reflection.options[:through] ? P8Through : P8Plain
          end
        end

        class P8Builder
          def self.stored(options) = P8Reflection.new(options)
          def self.keywords(**options) = P8Reflection.new(options)
        end

        class P8Use
          def a_through = P8Reflection.new({ through: :taggings }).kind
          def a_plain = P8Reflection.new({}).kind
          def b_through = P8Picker.pick(P8Reflection.new({ through: :taggings }))
          def b_plain = P8Picker.pick(P8Reflection.new({}))
          def c_through = P8Builder.stored({ through: :taggings }).kind
          def c_plain = P8Builder.stored({}).kind
          def d_through = P8Builder.keywords(through: :taggings).kind
          def d_plain = P8Builder.keywords.kind
        end
      RUBY
      types = specialized_body_types("app/pick.rb")

      %w[a b c d].each do |caller|
        assert_equal "singleton(::P8Through)", types.fetch("#{caller}_through"), caller
        assert_equal "singleton(::P8Plain)", types.fetch("#{caller}_plain"), caller
      end
    end
  end

  def test_a_hash_written_before_initialize_stores_it_reads_back_its_branch
    in_tmpdir do
      write("sig/pick.rbs", <<~RBS)
        class P9Plain
        end
        class P9Through
        end
        class P9Reflection
          @options: Hash[Symbol, untyped]
          attr_reader options: Hash[Symbol, untyped]
          def initialize: (Hash[Symbol, untyped] options) -> void
          def kind: () -> (singleton(P9Through) | singleton(P9Plain))
          private
          def normalized: (Hash[Symbol, untyped] options) -> Hash[Symbol, untyped]
        end
        class P9Builder
          def self.build: (**untyped) -> P9Reflection
        end
        class P9Use
          def through: () -> untyped
          def plain: () -> untyped
          def direct_through: () -> untyped
          def direct_plain: () -> untyped
        end
      RBS
      write("app/pick.rb", <<~RUBY)
        class P9Reflection
          attr_reader :options

          def initialize(options)
            @options = normalized(options)
          end

          def kind
            options[:through] ? P9Through : P9Plain
          end

          private

          def normalized(options)
            options.delete(:counter_cache)
            options
          end
        end

        class P9Builder
          def self.build(**options) = P9Reflection.new(options)
        end

        class P9Use
          def through = P9Builder.build(through: :taggings).kind
          def plain = P9Builder.build(counter_cache: true).kind
          def direct_through = P9Reflection.new({ through: :taggings, counter_cache: true }).kind
          def direct_plain = P9Reflection.new({ counter_cache: true }).kind
        end
      RUBY
      types = specialized_body_types("app/pick.rb")

      assert_equal "singleton(::P9Through)", types.fetch("through")
      assert_equal "singleton(::P9Plain)", types.fetch("plain")
      assert_equal "singleton(::P9Through)", types.fetch("direct_through")
      assert_equal "singleton(::P9Plain)", types.fetch("direct_plain")
    end
  end

  def test_a_subclass_new_running_an_inherited_initialize_is_its_own_class
    in_tmpdir do
      write("sig/pick.rbs", <<~RBS)
        class P10Base
          @options: Hash[Symbol, untyped]
          attr_reader options: Hash[Symbol, untyped]
          def initialize: (Hash[Symbol, untyped] options) -> void
          private
          def normalized: (Hash[Symbol, untyped] options) -> Hash[Symbol, untyped]
        end
        class P10Sub < P10Base
          def sub_only: () -> :sub
        end
        class P10Use
          def built: () -> untyped
          def through: () -> untyped
        end
      RBS
      write("app/pick.rb", <<~RUBY)
        class P10Base
          attr_reader :options

          def initialize(options)
            @options = normalized(options)
          end

          private

          def normalized(options)
            options.delete(:counter_cache)
            options
          end
        end

        class P10Sub < P10Base
          def sub_only = :sub
        end

        class P10Use
          def built = P10Sub.new({ through: :taggings })
          def through = P10Sub.new({ through: :taggings }).options[:through]
        end
      RUBY
      types = specialized_body_types("app/pick.rb")

      assert_match(/\A::P10Sub\b/, types.fetch("built"))
      assert_equal ":taggings", types.fetch("through")
    end
  end

  def test_a_hash_its_own_method_writes_follows_the_object_a_local_holds
    in_tmpdir do
      write("sig/pick.rbs", <<~RBS)
        class P11Plain
        end
        class P11Through
        end
        class P11Reflection
          @options: Hash[Symbol, untyped]
          attr_reader options: Hash[Symbol, untyped]
          def initialize: (Hash[Symbol, untyped] options) -> void
          def autosave=: (bool autosave) -> bool
          def kind: () -> (singleton(P11Through) | singleton(P11Plain))
          def saving: () -> (:saved | :unsaved)
          private
          def normalized: (Hash[Symbol, untyped] options) -> Hash[Symbol, untyped]
        end
        class P11Looped < P11Reflection
        end
        class P11Builder
          def self.kind: (**untyped) -> (singleton(P11Through) | singleton(P11Plain))
          def self.saving: (**untyped) -> (:saved | :unsaved)
          def self.looped: (**untyped) -> (:saved | :unsaved)
        end
        class P11Use
          def through: () -> untyped
          def plain: () -> untyped
          def saved: () -> untyped
          def looped: () -> untyped
          def unheld: () -> untyped
        end
      RBS
      write("app/pick.rb", <<~RUBY)
        class P11Reflection
          attr_reader :options

          def initialize(options)
            @options = normalized(options)
          end

          def autosave=(autosave)
            @options[:autosave] = autosave
          end

          def kind
            options[:through] ? P11Through : P11Plain
          end

          def saving
            options[:autosave] ? :saved : :unsaved
          end

          private

          def normalized(options)
            options.delete(:counter_cache)
            options
          end
        end

        class P11Looped < P11Reflection
          def autosave=(autosave)
            [1].each { @options[:autosave] = autosave }
            autosave
          end
        end

        class P11Builder
          def self.kind(**options)
            reflection = P11Reflection.new(options)
            reflection.autosave = true
            reflection.kind
          end

          def self.saving(**options)
            reflection = P11Reflection.new(options)
            reflection.autosave = true
            reflection.saving
          end

          def self.looped(**options)
            reflection = P11Looped.new(options)
            reflection.autosave = true
            reflection.saving
          end
        end

        class P11Use
          def through = P11Builder.kind(through: :taggings)
          def plain = P11Builder.kind(counter_cache: true)
          def saved = P11Builder.saving(through: :taggings)
          def looped = P11Builder.looped(through: :taggings)
          def unheld = P11Reflection.new({ through: :taggings }).kind
        end
      RUBY
      types = specialized_body_types("app/pick.rb")

      assert_equal "singleton(::P11Through)", types.fetch("through")
      assert_equal "singleton(::P11Plain)", types.fetch("plain")
      assert_equal ":saved", types.fetch("saved")
      assert_equal "(:saved | :unsaved)", types.fetch("looped")
      assert_equal "singleton(::P11Through)", types.fetch("unheld")
    end
  end

  def test_a_body_that_returns_early_leaves_what_every_way_out_holds_alike
    in_tmpdir do
      write("sig/early.rbs", <<~RBS)
        class P13Reflection
          @options: Hash[Symbol, untyped]
          attr_reader options: Hash[Symbol, untyped]
          def initialize: (Hash[Symbol, untyped] options) -> void
          def saving: () -> (:saved | :unsaved)
        end
        class P13Decided < P13Reflection
          def autosave=: (bool autosave) -> bool
        end
        class P13Open < P13Reflection
          def autosave=: (bool autosave) -> bool
        end
        class P13Alike < P13Reflection
          def autosave=: (bool autosave) -> bool
        end
        class P13Use
          def decided: () -> untyped
          def open: () -> untyped
          def alike: () -> untyped
        end
      RBS
      write("app/early.rb", <<~RUBY)
        class P13Reflection
          attr_reader :options

          def initialize(options)
            @options = options
          end

          def saving
            options[:autosave] ? :saved : :unsaved
          end
        end

        class P13Decided < P13Reflection
          def autosave=(autosave)
            return autosave unless autosave
            @options[:autosave] = autosave
          end
        end

        class P13Open < P13Reflection
          def autosave=(autosave)
            return autosave if [true, false].sample
            @options[:autosave] = autosave
          end
        end

        class P13Alike < P13Reflection
          def autosave=(autosave)
            @options[:autosave] = autosave
            return autosave if [true, false].sample
            autosave
          end
        end

        class P13Use
          def decided = P13Decided.new({}).tap { |reflection| reflection.autosave = true }.saving
          def open = P13Open.new({}).tap { |reflection| reflection.autosave = true }.saving
          def alike = P13Alike.new({}).tap { |reflection| reflection.autosave = true }.saving
        end
      RUBY
      types = specialized_body_types("app/early.rb")

      assert_equal ":saved", types.fetch("decided")
      assert_equal "(:saved | :unsaved)", types.fetch("open")
      assert_equal ":saved", types.fetch("alike")
    end
  end

  def test_a_new_whose_arguments_met_several_recorded_calls_answers_the_class
    in_tmpdir do
      write("sig/box.rbs", <<~RBS)
        class P12Box
          @value: Symbol
          attr_reader value: Symbol
          def initialize: (Symbol value) -> void
          def replace: (Symbol value) -> Symbol
        end
        class P12Use
          def build: ((:a | :c) value) -> P12Box
          def first: () -> untyped
          def second: () -> untyped
        end
      RBS
      write("app/box.rb", <<~RUBY)
        class P12Box
          attr_reader :value

          def initialize(value)
            @value = value
          end

          def replace(value)
            @value = value
          end
        end

        class P12Use
          def build(value) = P12Box.new(value)
          def first = build(:a)
          def second = build(:c)
        end
      RUBY
      types = specialized_body_types("app/box.rb")

      assert_equal "::P12Box", types.fetch("build")
    end
  end

  # `P13Status#options` shares the reader's name, and its hash is handed on.
  # Only a receiver that may be a `P13Reflection`, in any target that checks
  # it, counts against the reflection's `options`, `self` included; a reader
  # on another class that answers it counts by what that reader's own
  # receivers may be.
  def test_a_use_whose_receiver_is_another_class_does_not_count_against_the_reader
    union = "(singleton(::P13Through) | singleton(::P13Plain))"
    leak = "Kernel.puts(status.options)"
    cases = {
      [["P13Status"], leak] => "singleton(::P13Through)",
      [%w[P13Status P13Status], leak] => "singleton(::P13Through)",
      [["p13_status"], leak] => "singleton(::P13Through)",
      [["P13Status?"], "Kernel.puts(status&.options)"] => "singleton(::P13Through)",
      [["untyped"], leak] => union,
      [%w[P13Status untyped], leak] => union,
      [["P13Tagged"], leak] => union,
      [["P13Holder"], "status.held.delete(:through)"] => union,
      [["P13Status"], leak, "def copy = itself.options.delete(:through)"] => union
    }
    cases.each do |(receivers, body, own), through|
      in_tmpdir do
        targets = receivers.each_with_index.map do |receiver, index|
          write("sig_#{index}/leak.rbs", "class P13Leak\n  def self.leak: (#{receiver} status) -> void\nend\n")
          "target :t#{index} do\n  signature \"sig\", \"sig_#{index}\"\n  check \"app\"\nend\n"
        end
        write("sig/pick.rbs", <<~RBS)
          class P13Plain
          end
          class P13Through
          end
          class P13Reflection
            @options: Hash[Symbol, untyped]
            attr_reader options: Hash[Symbol, untyped]
            def initialize: (Hash[Symbol, untyped] options) -> void
            def kind: () -> (singleton(P13Through) | singleton(P13Plain))
            def copy: () -> untyped
          end
          class P13Status
            def options: () -> Hash[Symbol, untyped]
          end
          type p13_status = P13Status
          module P13Tagged
            def options: () -> Hash[Symbol, untyped]
          end
          class P13Holder
            @reflection: P13Reflection
            def initialize: (P13Reflection reflection) -> void
            def held: () -> Hash[Symbol, untyped]
          end
          class P13Use
            def through: () -> untyped
          end
        RBS
        write("app/pick.rb", <<~RUBY)
          class P13Reflection
            attr_reader :options

            def initialize(options)
              @options = options
            end

            def kind
              options[:through] ? P13Through : P13Plain
            end

            #{own}
          end

          class P13Holder
            def initialize(reflection)
              @reflection = reflection
            end

            def held = @reflection.options
          end

          class P13Leak
            def self.leak(status) = #{body}
          end

          class P13Use
            def through = P13Reflection.new({ through: :taggings }).kind
          end
        RUBY

        assert_equal through, specialized_body_types("app/pick.rb", steepfile: targets.join).fetch("through"), [*receivers, body].join(", ")
      end
    end
  end

  # `P14Tweaker` stores through the reader of an object no local of these
  # bodies holds. A store made through the reader off a local nothing else
  # names moves what that local holds; one made off any other name, through
  # a local it was read into, or not by literal key, leaves the hash unknown.
  def test_a_store_made_through_the_reader_moves_the_object_a_local_holds
    in_tmpdir do
      write("sig/box.rbs", <<~RBS)
        class P14Box
          @options: Hash[Symbol, untyped]
          attr_reader options: Hash[Symbol, untyped]
          def initialize: (Hash[Symbol, untyped] options) -> void
        end
        class P14Aliased
          @options: Hash[Symbol, untyped]
          attr_reader options: Hash[Symbol, untyped]
          def initialize: (Hash[Symbol, untyped] options) -> void
        end
        class P14Tweaker
          def self.tweak: (P14Box box) -> void
        end
        class P14Use
          def stored: () -> untyped
          def kept: () -> untyped
          def deleted: () -> untyped
          def safe: () -> untyped
          def other: () -> untyped
          def open_key: (Symbol key) -> untyped
          def looped: () -> untyped
          def tapped: () -> untyped
          def aliased: () -> untyped
        end
      RBS
      write("app/box.rb", <<~RUBY)
        class P14Box
          attr_reader :options

          def initialize(options)
            @options = options
          end
        end

        class P14Aliased
          attr_reader :options

          def initialize(options)
            @options = options
          end
        end

        class P14Tweaker
          def self.tweak(box) = box.options[:tweaked] = true
        end

        class P14Use
          def stored
            box = P14Box.new({ through: :taggings })
            box.options[:autosave] = true
            box.options[:autosave]
          end

          def kept
            box = P14Box.new({ through: :taggings })
            box.options[:autosave] = true
            box.options[:through]
          end

          def deleted
            box = P14Box.new({ through: :taggings })
            box.options.delete(:through)
            box.options[:through]
          end

          def safe
            box = P14Box.new({ through: :taggings })
            box&.options[:through] = :tags
            box.options[:through]
          end

          def other
            box = P14Box.new({ through: :taggings })
            other = P14Box.new({ through: :taggings })
            other.options[:through] = :tags
            box.options[:through]
          end

          def open_key(key)
            box = P14Box.new({ through: :taggings })
            box.options[key] = :tags
            box.options[:through]
          end

          def looped
            box = P14Box.new({ through: :taggings })
            [1].each { box.options[:through] = :tags }
            box.options[:through]
          end

          def tapped
            box = P14Box.new({ through: :taggings })
            box.tap { |tapped| tapped.options[:through] = :tags }
            box.options[:through]
          end

          def aliased
            box = P14Aliased.new({ through: :taggings })
            options = box.options
            options[:through] = :tags
            box.options[:through]
          end
        end
      RUBY
      types = specialized_body_types("app/box.rb")

      assert_equal "true", types.fetch("stored")
      assert_equal ":taggings", types.fetch("kept")
      assert_equal "nil", types.fetch("deleted")
      assert_equal ":tags", types.fetch("safe")
      assert_equal ":taggings", types.fetch("other")
      assert_equal "untyped", types.fetch("open_key")
      assert_equal "untyped", types.fetch("looped")
      assert_equal "untyped", types.fetch("tapped")
      assert_equal "untyped", types.fetch("aliased")
    end
  end

  # The object a store moves is held by an ivar of the caller, reached
  # through the caller's reader, and read by a method called afterwards: that
  # call's check leaves it as it found it, and `poke`'s leaves it written.
  # A second name for it, here or in a method called, an argument, a block,
  # `itself` or one held inside another object's state each leave it
  # unknown.
  def test_a_store_made_through_the_reader_moves_the_object_an_ivar_holds
    in_tmpdir do
      write("sig/runner.rbs", <<~RBS)
        class P15Foo
          @my_hash: Hash[Symbol, untyped]
          attr_reader my_hash: Hash[Symbol, untyped]
          def initialize: (Hash[Symbol, untyped] my_hash) -> void
        end
        class P15Writer
          def self.write: (P15Foo foo) -> void
        end
        class P15Holder
          @foo: P15Foo
          @ready: bool
          attr_reader foo: P15Foo
          def initialize: (bool ready) -> void
        end
        class P15Runner
          @foo: P15Foo?
          attr_reader foo: P15Foo?
          def run: () -> untyped
          def run_bar: () -> untyped
          def poked: () -> untyped
          def poke: () -> untyped
          def through_ivar: () -> untyped
          def aliased: () -> untyped
          def handed: () -> untyped
          def blocked: () -> untyped
          def itselfed: () -> untyped
          def nested: () -> untyped
          def sneaked: () -> untyped
          def sneak: () -> nil
        end
      RBS
      write("app/runner.rb", <<~RUBY)
        class P15Foo
          attr_reader :my_hash

          def initialize(my_hash)
            @my_hash = my_hash
          end
        end

        class P15Writer
          def self.write(foo) = foo.my_hash[:bar] = 5
        end

        class P15Holder
          attr_reader :foo

          def initialize(ready)
            @foo = P15Foo.new({})
            @ready = ready
          end
        end

        class P15Runner
          attr_reader :foo

          def run
            @foo = P15Foo.new({})
            foo.my_hash[:bar] = 10
            run_bar
            foo.my_hash[:bar] + 10
          end

          def run_bar
            foo.my_hash[:bar].to_s
          end

          def poked
            @foo = P15Foo.new({})
            foo.my_hash[:bar] = 10
            poke
            foo.my_hash[:bar]
          end

          def poke
            foo.my_hash[:bar] = 99
          end

          def through_ivar
            @foo = P15Foo.new({})
            @foo.my_hash[:bar] = 10
            @foo.my_hash[:bar]
          end

          def aliased
            @foo = P15Foo.new({})
            other = foo
            other.my_hash[:bar] = 99
            foo.my_hash[:bar]
          end

          def handed
            @foo = P15Foo.new({})
            foo.my_hash[:bar] = 10
            P15Writer.write(foo)
            foo.my_hash[:bar]
          end

          def blocked
            @foo = P15Foo.new({})
            foo.my_hash[:bar] = 10
            [1].each { foo.my_hash[:bar] = 99 }
            foo.my_hash[:bar]
          end

          def itselfed
            @foo = P15Foo.new({})
            foo.my_hash[:bar] = 10
            foo.itself.my_hash[:bar] = 99
            foo.my_hash[:bar]
          end

          def nested
            holder = P15Holder.new(true)
            holder.foo.my_hash[:bar] = 5
            holder.foo.my_hash[:bar]
          end

          def sneaked
            @foo = P15Foo.new({})
            foo.my_hash[:bar] = 10
            sneak
            foo.my_hash[:bar]
          end

          def sneak
            [1].each { foo.my_hash[:bar] = 7 }
            nil
          end
        end
      RUBY
      types = specialized_body_types("app/runner.rb")

      assert_equal "20", types.fetch("run")
      assert_equal "99", types.fetch("poked")
      assert_equal "10", types.fetch("through_ivar")
      %w[aliased handed blocked itselfed nested sneaked].each do |name|
        assert_equal "untyped", types.fetch(name), name
      end
    end
  end

  # example99's hash of hashes: a literal stored where nothing takes its
  # value stays a record while every read of it is a step of a followed
  # path, through the reader or `Foo`'s own ivar. Read into a local,
  # returned, copied, read by a key that is no literal, its store's value
  # taken, or changed where the path is not followed, it is held as its
  # class. A nested record a signature declares (`P16Cfg`) is left as
  # declared.
  def test_a_record_stored_under_a_key_stays_a_record_while_every_path_to_it_is_followed
    in_tmpdir do
      write("sig/nested.rbs", <<~RBS)
        class P16Foo
          @my_hash: Hash[untyped, untyped]
          attr_reader my_hash: Hash[untyped, untyped]
          def initialize: (Hash[untyped, untyped] my_hash) -> void
          def sum: () -> untyped
          def bump: () -> nil
          def stash: () -> nil
          def leak: () -> nil
          def looped_bump: () -> nil
        end
        class P16Cfg
          @cfg: { db: { host: String } }
          attr_reader cfg: { db: { host: String } }
          def initialize: ({ db: { host: String } } cfg) -> void
          def ivar: () -> void
          def reader: () -> void
          def param: ({ db: { host: String } } opts) -> void
          def use: ({ db: { host: String } } cfg) -> void
        end
        class P16Runner
          @foo: P16Foo?
          attr_reader foo: P16Foo?
          def run: () -> untyped
          def build: () -> untyped
          def num1: () -> untyped
          def change: () -> untyped
          def give: () -> untyped
          def local_alias: () -> untyped
          def returned_alias: () -> untyped
          def built_alias: () -> untyped
          def taken_store: () -> untyped
          def merged: () -> untyped
          def fetched: () -> untyped
          def bumped: () -> untyped
          def stashed: () -> untyped
          def outer_alias: () -> untyped
          def leaked: () -> untyped
          def looped: () -> untyped
          def keyed: (Symbol key) -> untyped
        end
      RBS
      write("app/nested.rb", <<~RUBY)
        class P16Foo
          attr_reader :my_hash

          def initialize(my_hash)
            @my_hash = my_hash
          end

          def sum
            @my_hash[:bar][:num1] + @my_hash[:bar][:num2]
          end

          def bump
            @my_hash[:bar][:num1] = 7
            nil
          end

          def stash
            stashed = @my_hash[:bar]
            stashed[:num1] = 1
            nil
          end

          def leak
            copy = @my_hash.merge(extra: 1)
            copy[:bar][:num1] = 1
            nil
          end

          def looped_bump
            [1].each { @my_hash[:bar][:num1] = 3 }
            nil
          end
        end

        class P16Cfg
          attr_reader :cfg

          def initialize(cfg)
            @cfg = cfg
          end

          def ivar = use(@cfg)
          def reader = use(cfg)

          def param(opts)
            db = opts[:db]
            use(opts)
            db
          end

          def use(cfg) = nil
        end

        class P16Runner
          attr_reader :foo

          def run
            @foo = P16Foo.new({})
            build
            num1
            change
            foo.sum
            foo.my_hash[:bar][:num2].to_s
          end

          def build
            foo.my_hash[:bar] = { num1: 5, num2: 10 }
          end

          def num1
            foo.my_hash[:bar][:num1]
          end

          def change
            foo.my_hash[:bar][:num2] = foo.my_hash[:bar][:num2] + 20
          end

          def give = foo.my_hash[:bar]

          def local_alias
            @foo = P16Foo.new({})
            build
            inner = foo.my_hash[:bar]
            inner[:num1] = 99
            foo.my_hash[:bar][:num1]
          end

          def returned_alias
            @foo = P16Foo.new({})
            build
            inner = give
            inner[:num1] = 99
            foo.my_hash[:bar][:num1]
          end

          def built_alias
            @foo = P16Foo.new({})
            inner = build
            inner[:num1] = 99
            foo.my_hash[:bar][:num1]
          end

          def taken_store
            @foo = P16Foo.new({})
            inner = (foo.my_hash[:bar] = { num1: 5 })
            inner[:num1] = 99
            foo.my_hash[:bar][:num1]
          end

          def merged
            @foo = P16Foo.new({})
            build
            foo.my_hash[:bar].merge!(num1: 99)
            foo.my_hash[:bar][:num1]
          end

          def fetched
            @foo = P16Foo.new({})
            build
            foo.my_hash.fetch(:bar)[:num1] = 99
            foo.my_hash[:bar][:num1]
          end

          def bumped
            @foo = P16Foo.new({})
            build
            foo.bump
            foo.my_hash[:bar][:num1]
          end

          def stashed
            @foo = P16Foo.new({})
            build
            foo.stash
            foo.my_hash[:bar][:num1]
          end

          def outer_alias
            @foo = P16Foo.new({})
            build
            outer = foo.my_hash
            outer[:bar][:num1] = 99
            foo.my_hash[:bar][:num1]
          end

          def leaked
            @foo = P16Foo.new({})
            build
            foo.leak
            foo.my_hash[:bar][:num1]
          end

          def looped
            @foo = P16Foo.new({})
            build
            foo.looped_bump
            foo.my_hash[:bar][:num1]
          end

          def keyed(key)
            @foo = P16Foo.new({})
            build
            foo.my_hash[key][:num1] = 99
            foo.my_hash[:bar][:num1]
          end
        end
      RUBY
      types = specialized_body_types("app/nested.rb")
      checked = checked(setup_project.tap(&:reload_specializations!), current_dir + "app/nested.rb")
      assert_empty checked.errors.grep(Steep::Diagnostic::Ruby::UnresolvedOverloading).map(&:header_line)
      assert_empty checked.errors.grep(Steep::Diagnostic::Ruby::ArgumentTypeMismatch).map(&:header_line)
      declarations = YAML.load_file(current_dir + "sig/generated/.steep_specializations.yml").fetch("declarations")

      assert_equal({ "P16Foo#sum" => "35", "P16Runner#build" => "{ :num1 => 5, :num2 => 10 }", "P16Runner#change" => "30", "P16Runner#num1" => "5" },
                   declarations.slice("P16Foo#sum", "P16Runner#build", "P16Runner#change", "P16Runner#num1"))
      assert_equal '"30"', types.fetch("run")
      assert_equal "7", types.fetch("bumped")
      %w[local_alias returned_alias built_alias merged fetched stashed outer_alias leaked looped keyed].each do |name|
        assert_equal "untyped", types.fetch(name), name
      end
      assert_equal "::Integer", types.fetch("taken_store")
    end
  end

  def test_a_hash_written_under_any_name_keeps_what_no_write_touches
    in_tmpdir do
      write("sig/registry.rbs", <<~RBS)
        class P17Plain
        end
        class P17Through
        end
        class P17Reflection
          @options: Hash[Symbol, untyped]
          attr_reader options: Hash[Symbol, untyped]
          def initialize: (Hash[Symbol, untyped] options) -> void
          def autosave=: (bool autosave) -> bool
          def kind: () -> (singleton(P17Through) | singleton(P17Plain))
        end
        class P17Base
          self.@registry: Hash[Symbol, P17Reflection]
          def self.registry: () -> Hash[Symbol, P17Reflection]
          def self.has_many: (Symbol name, **untyped options) -> P17Reflection
          def self.nested: (Symbol name) -> bool
          def self.lookup: (Symbol name) -> P17Reflection
        end
        class P17Post < P17Base
          def tags: () -> untyped
          def comments: () -> untyped
          def tags_through: () -> untyped
          def tags_autosave: () -> untyped
        end
      RBS
      write("app/registry.rb", <<~RUBY)
        class P17Reflection
          attr_reader :options

          def initialize(options)
            @options = options
          end

          def autosave=(autosave)
            @options[:autosave] = autosave
          end

          def kind = options[:through] ? P17Through : P17Plain
        end

        class P17Base
          def self.registry
            @registry ||= {}
          end

          def self.has_many(name, **options)
            registry[name] = P17Reflection.new(options)
          end

          def self.nested(name)
            lookup(name).autosave = true
          end

          def self.lookup(name)
            registry[name]
          end
        end

        class P17Post < P17Base
          has_many :tags, through: :taggings
          has_many :comments
          nested :tags

          def tags = self.class.lookup(:tags).kind
          def comments = self.class.lookup(:comments).kind
          def tags_through = self.class.lookup(:tags).options[:through]
          def tags_autosave = self.class.lookup(:tags).options[:autosave]
        end
      RUBY
      types = specialized_body_types("app/registry.rb")

      assert_equal "singleton(::P17Through)", types.fetch("tags")
      assert_equal "singleton(::P17Plain)", types.fetch("comments")
      assert_equal ":taggings", types.fetch("tags_through")
      assert_equal "untyped", types.fetch("tags_autosave")
    end
  end

  def test_a_hash_a_local_holds_is_followed_into_the_methods_it_is_handed_to
    in_tmpdir do
      write("sig/handed.rbs", <<~RBS)
        class P18Foo
          @kept: untyped
          def run: () -> untyped
          def call_num1: (Hash[untyped, untyped] my_hash) -> untyped
          def call_num2: (Hash[untyped, untyped] my_hash) -> untyped
          def change_num2: (Hash[untyped, untyped] my_hash) -> untyped
          def flat: () -> untyped
          def widened_at_a_new_key: () -> untyped
          def kept: () -> untyped
          def keep: (Hash[untyped, untyped] my_hash) -> nil
          def returned: () -> untyped
          def same: (Hash[untyped, untyped] my_hash) -> Hash[untyped, untyped]
          def keyed: (Symbol key) -> untyped
          def write_by: (Hash[untyped, untyped] my_hash, Symbol key) -> nil
          def early: () -> untyped
          def early_write: (Hash[untyped, untyped] my_hash) -> nil
          def core: () -> untyped
          def aliased: () -> untyped
          def looped: () -> untyped
          def bump: (Hash[untyped, untyped] my_hash) -> nil
        end
      RBS
      write("app/handed.rb", <<~RUBY)
        class P18Foo
          def run
            my_hash = {}
            my_hash[:bar] = { num1: 5, num2: 10 }
            call_num1(my_hash)
            call_num2(my_hash)
            change_num2(my_hash)
            my_hash[:bar][:num2].to_s
          end

          def call_num1(my_hash)
            my_hash[:bar][:num1]
          end

          def call_num2(my_hash)
            my_hash[:bar][:num2]
          end

          def change_num2(my_hash)
            my_hash[:bar][:num2] = my_hash[:bar][:num2] + 20
          end

          def flat
            h = {}
            h[:bar] = 10
            h[:bar]
          end

          def widened_at_a_new_key
            g = { a: 1 }
            g[:bar] = 10
            g[:a]
          end

          def kept
            h = { num: 1 }
            keep(h)
            h[:num]
          end

          def keep(my_hash)
            @kept = my_hash
            nil
          end

          def returned
            h = { num: 1 }
            other = same(h)
            other[:num] = 2
            h[:num]
          end

          def same(my_hash) = my_hash

          def keyed(key)
            h = { num: 1 }
            write_by(h, key)
            h[:num]
          end

          def write_by(my_hash, key)
            my_hash[key] = 2
            nil
          end

          def early
            h = { num: 1 }
            early_write(h)
            h[:num]
          end

          def early_write(my_hash)
            return nil if my_hash.empty?

            my_hash[:num] = 2
            nil
          end

          def core
            h = { num: 1 }
            Array(h)
            h[:num]
          end

          def aliased
            h = { num: 1 }
            other = h
            other[:num] = 2
            h[:num]
          end

          def looped
            h = { num: 1 }
            [1].each { bump(h) }
            h[:num]
          end

          def bump(my_hash)
            my_hash[:num] = 2
            nil
          end
        end
      RUBY
      types = specialized_body_types("app/handed.rb")
      checked = checked(setup_project.tap(&:reload_specializations!), current_dir + "app/handed.rb")
      declarations = YAML.load_file(current_dir + "sig/generated/.steep_specializations.yml").fetch("declarations")

      assert_empty checked.errors.map(&:header_line)
      assert_equal({ "P18Foo#call_num1" => "5", "P18Foo#call_num2" => "10", "P18Foo#change_num2" => "30" },
                   declarations.slice("P18Foo#call_num1", "P18Foo#call_num2", "P18Foo#change_num2"))
      assert_equal '"30"', types.fetch("run")
      assert_equal "10", types.fetch("flat")
      assert_equal "1", types.fetch("widened_at_a_new_key")
      %w[kept returned keyed early core].each do |name|
        assert_equal "untyped", types.fetch(name), name
      end
      assert_equal "::Integer", types.fetch("aliased")
      assert_equal "::Integer", types.fetch("looped")
    end
  end

  def test_a_nested_write_on_a_record_a_parameter_declares_moves_it
    in_tmpdir do
      write("sig/declared.rbs", <<~RBS)
        class P19Foo
          def change: ({ bar: { num1: 5, num2: 10 } } my_hash) -> 30
          def reread: ({ bar: { num1: 5, num2: 10 } } my_hash) -> untyped
          def keyed: ({ bar: { num1: 5, num2: 10 } } my_hash, Symbol key) -> untyped
        end
      RBS
      write("app/declared.rb", <<~RUBY)
        class P19Foo
          def change(my_hash)
            my_hash[:bar][:num2] = my_hash[:bar][:num2] + 20
          end

          def reread(my_hash)
            my_hash[:bar][:num2] = 30
            my_hash[:bar][:num2]
          end

          def keyed(my_hash, key)
            my_hash[:bar][key] = 30
            my_hash[:bar][:num2]
          end
        end
      RUBY
      types = specialized_body_types("app/declared.rb")
      checked = checked(setup_project.tap(&:reload_specializations!), current_dir + "app/declared.rb")

      assert_empty checked.errors.map(&:header_line)
      assert_equal "30", types.fetch("change")
      assert_equal "30", types.fetch("reread")
      assert_equal "untyped", types.fetch("keyed")
    end
  end

  P20_RBS = <<~RBS
    class P20Box
      @entries: Hash[Symbol, Symbol]
      def initialize: () -> void
      def put: (Symbol key, Symbol value) -> Symbol
      def get: (Symbol key) -> Symbol?
    end
    class P20Backend
      @entries: Hash[Symbol, Symbol]
      def initialize: (?Symbol? default) -> void
      def put: (Symbol key, Symbol value) -> Symbol
      def get: (Symbol key) -> Symbol?
      def reset: () -> Hash[Symbol, Symbol]
      def share: (Hash[Symbol, Symbol] other) -> untyped
      private
      def set_entries: (Symbol? default) -> Hash[Symbol, Symbol]
    end
    class P20Map < P20Backend
      @lock: Integer
      def initialize: (?Symbol? default) -> void
    end
    class P20Labels
      @labels: Hash[Symbol, String]
      @fallback: Symbol?
      def initialize: () -> void
      def get: (Symbol key) -> String?
      def fallback: () -> Symbol?
    end
    class P20Use
      def label: () -> untyped
      def fallback: () -> untyped
      def direct: () -> untyped
      def through_super: () -> untyped
      def missing: () -> untyped
      def defaulted: () -> untyped
    end
  RBS

  def p20_source(backend: "", defaulted_entries: "Hash.new(default)", entries: "{}")
    <<~RUBY
      class P20Box
        def initialize
          @entries = {}
        end

        def put(key, value)
          @entries[key] = value
        end

        def get(key)
          @entries[key]
        end
      end

      class P20Backend
        def initialize(default = nil)
          set_entries(default)
        end

        def put(key, value)
          @entries[key] = value
        end

        def get(key)
          @entries[key]
        end
      #{backend.gsub(/^/, "  ")}

        private

        def set_entries(default)
          if default
            @entries = #{defaulted_entries}
          else
            @entries = #{entries}
          end
        end
      end

      class P20Map < P20Backend
        def initialize(default = nil)
          super(default)
          @lock = 1
        end
      end

      class P20Labels
        def initialize
          @labels = { a: "x" }
          @fallback = nil
        end

        def get(key)
          @labels[key]
        end

        def fallback
          @fallback
        end
      end

      class P20Use
        def label
          labels = P20Labels.new
          labels.get(:a)
        end

        def fallback
          labels = P20Labels.new
          labels.fallback
        end

        def direct
          box = P20Box.new
          box.put(:a, :x)
          box.get(:a)
        end

        def through_super
          map = P20Map.new
          map.put(:a, :x)
          map.get(:a)
        end

        def missing
          map = P20Map.new
          map.put(:a, :x)
          map.get(:b)
        end

        def defaulted
          map = P20Map.new(:none)
          map.put(:a, :x)
          map.get(:a)
        end
      end
    RUBY
  end

  def test_a_hash_the_initialize_chain_sets_is_followed_through_super_and_a_method_it_calls_on_self
    in_tmpdir do
      write("sig/map.rbs", P20_RBS)
      write("app/map.rb", p20_source)
      types = specialized_body_types("app/map.rb")

      assert_equal ":x", types.fetch("direct")
      assert_equal ":x", types.fetch("through_super")
      assert_equal "nil", types.fetch("missing")
      assert_equal "(::String | nil)", types.fetch("label")
      assert_equal "nil", types.fetch("fallback")
      assert_equal "(::Symbol | nil)", types.fetch("defaulted")
    end
  end

  def test_a_branch_of_the_initialize_chain_the_call_never_runs_does_not_hand_self_on
    in_tmpdir do
      write("sig/map.rbs", P20_RBS)
      write("app/map.rb", p20_source(defaulted_entries: "Hash.new { |_entries, key| [self, key] && default }"))
      types = specialized_body_types("app/map.rb")

      assert_equal ":x", types.fetch("through_super")
      assert_equal "nil", types.fetch("missing")
      assert_equal "(::Symbol | nil)", types.fetch("defaulted")
    end
  end

  def test_declines_where_the_branch_the_call_runs_hands_self_on
    in_tmpdir do
      write("sig/map.rbs", P20_RBS)
      write("app/map.rb", p20_source(entries: "Hash.new { |_entries, key| [self, key] && nil }"))
      types = specialized_body_types("app/map.rb")

      assert_equal "(::Symbol | nil)", types.fetch("through_super")
    end
  end

  def test_declines_a_hash_the_initialize_chain_sets_that_something_else_may_change
    {
      "a method run after initialize sets it" => "def reset = set_entries(nil)",
      "a method hands it on" => "def share(other) = other.replace(@entries)"
    }.each do |label, backend|
      in_tmpdir do
        write("sig/map.rbs", P20_RBS)
        write("app/map.rb", p20_source(backend: backend))
        types = specialized_body_types("app/map.rb")

        assert_equal ":x", types.fetch("direct"), label
        assert_equal "(::Symbol | nil)", types.fetch("through_super"), label
      end
    end
  end

  private

  def specialized_body_types(path, steepfile: STEEPFILE)
    project = setup_project(steepfile: steepfile)
    postconditions = Steep::Postconditions::Runner.new(project)
    postconditions.write(postconditions.run)
    project = setup_project(steepfile: steepfile)
    runner = Steep::Specializations::Runner.new(project)
    runner.write(runner.run)
    project.reload_specializations!

    body_types(project, current_dir + path)
  end
end

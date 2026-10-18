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
      assert_equal "(singleton(::P11Through) | singleton(::P11Plain))", types.fetch("unheld")
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

require_relative "test_helper"
require_relative "specializations_project_helper"
require "timeout"

class SpecializationsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  Specializations = Steep::Specializations

  # The entries every class shares, without the ones keyed by the class a
  # call was made on.
  def unkeyed(entries)
    entries.reject { |key, _| key.include?(Specializations::Arguments::SELF_MARKER) }
  end


  FIXTURE_RBS = <<~RBS
    module Example
      class Foo
        def name: () -> "name"
        def action: () -> "delete"
        def call_name_action: () -> String
        def call_action: () -> String
        def call_unknown: (flag_name: untyped) -> String

        private

        def call: (?flag_name: bool) -> String
      end
    end
  RBS

  FIXTURE_RUBY = <<~RUBY
    module Example
      class Foo
        def name
          "name"
        end

        def action
          "delete"
        end

        def call_name_action
          call(flag_name: true)
        end

        def call_action
          call(flag_name: false)
        end

        def call_unknown(flag_name:)
          call(flag_name: flag_name)
        end

        private

        def call(flag_name: false)
          if flag_name
            "\#{name}_\#{action}"
          else
            action
          end
        end
      end
    end
  RUBY

  def test_runner_records_one_return_per_argument_tuple
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)

      methods = Specializations::Runner.run(setup_project)

      assert_equal(
        { "(flag_name: true)" => '"name_delete"', "(flag_name: false)" => '"delete"' },
        methods.fetch("Example::Foo#call")
      )
    end
  end

  def test_runner_records_what_a_string_eval_returns_at_each_call_site
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          def self.stamp_target: (Symbol name) -> untyped
        end
        class Target
        end
        class Article < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.stamp_target(name)
            Target.class_eval "def \#{name}_on_target = 1"
          end
        end

        class Article < Base
          stamp_target :published
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(:published)" => ":published_on_target" }, methods.fetch("Base.stamp_target"))
    end
  end

  def test_runner_records_an_inherited_class_method_called_on_a_subclass
    in_tmpdir do
      write("sig/base.rbs", "class Base\n  def self.label: (Symbol name) -> Symbol\nend\nclass Widget < Base\nend\n")
      write("app/base.rb", <<~RUBY)
        class Base
          def self.label(name)
            name
          end
        end

        class Widget < Base
          label(:size)
        end

        Widget.label(:weight)
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(:size)" => ":size", "(:weight)" => ":weight" }, methods.fetch("Base.label"))
    end
  end

  def test_runner_checks_an_inherited_class_method_on_the_subclass_whose_override_it_calls
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          def self.build: (untyped name) -> untyped
          def self.macro: () -> untyped
          def self.create: (untyped macro, untyped name) -> untyped
        end
        class HasMany < Base
          def self.macro: () -> :has_many
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.build(name)
            create(macro, name)
          end

          def self.macro
            raise NotImplementedError
          end

          def self.create(macro, name)
            macro
          end
        end

        class HasMany < Base
          def self.macro
            :has_many
          end
        end

        HasMany.build(:comments)
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(:comments) on singleton(::HasMany)" => ":has_many" }, methods.fetch("Base.build"))
      assert_equal({ "(:has_many, :comments)" => ":has_many" }, methods.fetch("Base.create"))
    end
  end

  def test_runner_does_not_key_an_inherited_class_method_by_a_subclass_that_overrides_nothing_it_calls
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          def self.build: (untyped name) -> untyped
          def self.macro: () -> :base
          def self.create: (untyped macro, untyped name) -> untyped
        end
        class Plain < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.build(name)
            create(macro, name)
          end

          def self.macro
            :base
          end

          def self.create(macro, name)
            macro
          end
        end

        class Plain < Base
        end

        Plain.build(:comments)
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(:comments)" => ":base" }, methods.fetch("Base.build"))
    end
  end

  def test_runner_records_the_constant_a_const_get_of_a_literal_names
    in_tmpdir do
      write("sig/lookup.rbs", <<~RBS)
        class Post
        end
        class Lookup
          def self.find: (String name) -> untyped
        end
        module Finder
          def methods_module: () -> untyped
        end
        module Holder
          extend Finder
          module Methods
          end
        end
      RBS
      write("app/lookup.rb", <<~RUBY)
        class Lookup
          def self.find(name) = Object.const_get(name)
        end

        module Finder
          def methods_module = const_get(:Methods)
        end

        module Holder
          extend Finder

          methods_module
        end

        Lookup.find("Post")
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ '("Post")' => "singleton(::Post)" }, methods.fetch("Lookup.find"))
      assert_equal(["singleton(::Holder::Methods)"], methods.fetch("Finder#methods_module").values)
    end
  end

  def test_runner_specializes_on_the_keywords_a_keyword_rest_collects
    in_tmpdir do
      write("sig/pick.rbs", <<~RBS)
        class P7Plain
        end
        class P7Through
        end
        class P7Pick
          def self.association_class: (Symbol name, ?scope: Symbol, **untyped) -> untyped
        end
      RBS
      write("app/pick.rb", <<~RUBY)
        class P7Pick
          def self.association_class(name, scope: :all, **options)
            options[:through] ? P7Through : P7Plain
          end
        end

        P7Pick.association_class(:posts, through: :taggings)
        P7Pick.association_class(:tags, scope: :recent)
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal(
        {
          "(:posts, **{ :through => :taggings })" => "singleton(::P7Through)",
          "(:tags, scope: :recent, **{  })" => "singleton(::P7Plain)"
        },
        methods.fetch("P7Pick.association_class")
      )
    end
  end

  def test_runner_specializes_on_a_hash_literal_argument
    in_tmpdir do
      write("sig/pick.rbs", <<~RBS)
        class P6Plain
        end
        class P6Through
        end
        class P6Pick
          def self.association_class: (untyped options) -> untyped
        end
      RBS
      write("app/pick.rb", <<~RUBY)
        class P6Pick
          def self.association_class(options)
            options[:through] ? P6Through : P6Plain
          end
        end

        P6Pick.association_class({ through: :posts })
        P6Pick.association_class({})
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal(
        { "({ :through => :posts })" => "singleton(::P6Through)", "({  })" => "singleton(::P6Plain)" },
        methods.fetch("P6Pick.association_class")
      )
    end
  end

  def test_runner_keeps_an_inherited_call_beside_a_memo_it_does_not_read
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          self.@registry: Module?
          def self.registry: () -> Module
          def self.label: (Symbol name) -> Symbol
        end
        class Widget < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.registry
            @registry ||= const_set(:Registry, Module.new)
          end

          def self.label(name)
            name
          end
        end

        class Widget < Base
          label(:size)
        end
      RUBY

      assert_equal({ "(:size)" => ":size" }, Specializations::Runner.run(setup_project).fetch("Base.label"))
    end
  end

  def test_runner_records_nothing_for_a_call_that_fixes_no_literal
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)

      methods = Specializations::Runner.run(setup_project)

      refute_includes methods.keys, "Example::Foo#call_unknown"
    end
  end

  def test_runner_specializes_a_positional_argument
    in_tmpdir do
      write("sig/foo.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def label: (bool) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet
            label(true)
          end

          def label(loud)
            if loud
              "LOUD"
            else
              "quiet"
            end
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(true)" => '"LOUD"' }, methods.fetch("Bar#label"))
    end
  end

  # A rest parameter holds the arguments its call passed, in order and no more:
  # the call builds that array, so the body checked for that call reads it as
  # a tuple — the count of an `each` over it included. Anything that could
  # change it unseen (a mutating call, a second name) takes that away.
  def test_runner_reads_a_rest_parameter_as_the_arguments_passed
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def two: () -> String
          def one: () -> String
          def trailing: () -> String
          def after_optional: () -> String
          def nothing_left: () -> String
          def with_a_push: () -> String
          def through_join: () -> String
          def reversed: () -> String
          def aliased: () -> String
          def names: (*Symbol) -> String
          def pair: (Symbol, *Symbol, Symbol) -> String
          def opt: (Symbol, ?Symbol, *Symbol) -> String
          def tail: (Symbol, *Symbol) -> String
          def pushed: (*Symbol) -> String
          def joined: (*String) -> String
          def mutated: (*Symbol) -> String
          def leaked: (*Symbol) -> String
        end
      RBS
      write("app/bar.rb", <<~'RUBY')
        class Bar
          def two = names(:a, :b)
          def one = names(:a)
          def trailing = pair(:h, :m1, :m2, :t)
          def after_optional = opt(:a, :b, :c)
          def nothing_left = tail(:a)
          def with_a_push = pushed(:a)
          def through_join = joined("a", "b")
          def reversed = mutated(:a, :b)
          def aliased = leaked(:a)

          def names(*ms)
            parts = []
            ms.each { |m| parts << "def #{m}" }
            parts.join(";")
          end

          # The type of a method has no place for a positional after the rest,
          # so the count comes from the definition: `:t` is not one of `ms`.
          def pair(h, *ms, t)
            parts = []
            ms.each { |m| parts << "#{h}#{m}" }
            parts.join(";")
          end

          def opt(a, b = :d, *ms)
            parts = ["#{a}#{b}"]
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end

          def tail(a, *ms)
            parts = ["#{a}"]
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end

          def pushed(*ms)
            ms << :z
            parts = []
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end

          def joined(*ms)
            ms.join(",")
          end

          def mutated(*ms)
            ms.reverse!
            parts = []
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end

          def leaked(*ms)
            other = ms
            other << :q
            parts = []
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(:a, :b)" => '"def a;def b"', "(:a)" => '"def a"' }, methods.fetch("Bar#names"))
      assert_equal({ "(:h, :m1, :m2, :t)" => '"hm1;hm2"' }, methods.fetch("Bar#pair"))
      assert_equal({ "(:a, :b, :c)" => '"ab;c"' }, methods.fetch("Bar#opt"))
      assert_equal({ "(:a)" => '"a"' }, methods.fetch("Bar#tail"))
      assert_equal({ "(:a)" => '"a;z"' }, methods.fetch("Bar#pushed"))
      assert_equal({ '("a", "b")' => '"a,b"' }, methods.fetch("Bar#joined"))
      refute methods.key?("Bar#mutated")
      refute methods.key?("Bar#leaked")
    end
  end

  # A frame that hands its rest parameter on: the array it hands is the one the
  # call built, and nothing touched it before the hand-off, so the callee's
  # parameter arrives holding exactly that — and the call site is keyed on it.
  # Anything that could have changed it first, or a second name for it in the
  # same call, takes that away.
  def test_runner_follows_a_collection_handed_to_another_method
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def positional: () -> String
          def keyword: () -> String
          def mutated_first: () -> String
          def handed_twice: () -> String
          def outer: (*Symbol) -> String
          def outer_kw: (*Symbol) -> String
          def outer_mutates: (*Symbol) -> String
          def outer_twice: (*Symbol) -> String
          def gen: (untyped owner, Array[Symbol] methods) -> String
          def gen_kw: (methods: Array[Symbol]) -> String
          def gen_pair: (Array[Symbol] a, Array[Symbol] b) -> String
        end
      RBS
      write("app/bar.rb", <<~'RUBY')
        class Bar
          def positional = outer(:email)
          def keyword = outer_kw(:a, :b)
          def mutated_first = outer_mutates(:a, :b)
          def handed_twice = outer_twice(:a)

          def outer(*methods)
            gen(self, methods)
          end

          def outer_kw(*methods)
            gen_kw(methods: methods)
          end

          def outer_mutates(*methods)
            methods.reverse!
            gen(self, methods)
          end

          def outer_twice(*methods)
            gen_pair(methods, methods)
          end

          def gen(owner, methods)
            parts = []
            methods.each { |m| parts << "def #{m}" }
            parts.join(";")
          end

          def gen_kw(methods:)
            parts = []
            methods.each { |m| parts << "def #{m}" }
            parts.join(";")
          end

          def gen_pair(a, b)
            parts = []
            a.each { |m| parts << "def #{m}" }
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(:email)" => '"def email"' }, methods.fetch("Bar#outer"))
      assert_equal({ "(self, [:email])" => '"def email"' }, methods.fetch("Bar#gen"))
      assert_equal({ "(:a, :b)" => '"def a;def b"' }, methods.fetch("Bar#outer_kw"))
      assert_equal({ "(methods: [:a, :b])" => '"def a;def b"' }, methods.fetch("Bar#gen_kw"))
      refute methods.key?("Bar#outer_mutates")
      refute methods.key?("Bar#outer_twice")
      refute methods.key?("Bar#gen_pair")
    end
  end

  # What a callee's parameter arrives holding is known only for a call made
  # once, with an array nothing but this body could have changed. A hand-off in
  # a block runs once per pass, the callee pushing onto the array each time; a
  # method DECLARED to return a tuple may hand back an array anyone pushed onto.
  def test_runner_declines_a_hand_off_it_cannot_follow
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          @names: [:a]
          def looped: () -> void
          def outer_loops: (*Symbol) -> void
          def declared: () -> String
          def names: () -> [:a]
          def gen: (Array[Symbol] methods) -> String
        end
      RBS
      write("app/bar.rb", <<~'RUBY')
        class Bar
          def looped = outer_loops(:a)

          def outer_loops(*methods)
            [1, 2].each { gen(methods) }
            nil
          end

          def names = (@names ||= [:a])

          def declared
            names.push(:z)
            gen(names)
          end

          def gen(methods)
            methods << :b
            parts = []
            methods.each { |m| parts << "def #{m}" }
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      refute methods.key?("Bar#gen")
    end
  end

  # An expanded `each` runs its passes in order, so a pass reads what the one
  # before it wrote. The argument fixes `first` and `cur` for the first pass
  # only: decided again on the second, from the write.
  def test_runner_threads_a_loop_pass_into_the_next
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def shout: () -> String
          def label: (bool) -> String
          def echo: (String) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet
            label(true)
          end

          def shout
            echo("a")
          end

          def label(first)
            parts = []
            ["x", "y"].each do |piece|
              if first
                parts << piece
              else
                parts << "rest"
              end
              first = false
            end
            parts.join(";")
          end

          def echo(cur)
            parts = []
            ["x", "y"].each do |piece|
              parts << cur
              cur = "b"
            end
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(true)" => '"x;rest"' }, methods.fetch("Bar#label"))
      assert_equal({ '("a")' => '"a;b"' }, methods.fetch("Bar#echo"))
    end
  end

  # Each pass rebinds the parameter to the next element, which invalidates the
  # calls cached on it — and a conditional in the body joined them back to the
  # first element's answer. ActiveSupport's `generate` has that shape, and
  # `delegate :a, :b` defined `a` twice.
  def test_runner_binds_each_pass_to_its_own_element_across_a_join
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def names: (bool) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet
            names(true)
          end

          def names(flag)
            parts = []
            [:x, :y].each do |name|
              suffix = flag ? "!" : "?"
              name = name.to_s
              parts << "\#{name}\#{suffix}"
            end
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(true)" => '"x!;y!"' }, methods.fetch("Bar#names"))
    end
  end

  # felixefelip/rbs_infer#345 stage S5. `relay` has no literal in its own body —
  # it hands its parameter on — so its return is only specializable once `label`
  # already is, which is a second generation.
  def test_runner_carries_a_literal_across_two_calls
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def relay: (bool) -> String
          def label: (bool) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet
            relay(true)
          end

          def relay(loud)
            label(loud)
          end

          def label(loud)
            if loud
              "LOUD"
            else
              "quiet"
            end
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(true)" => '"LOUD"' }, methods.fetch("Bar#label"))
      assert_equal({ "(true)" => '"LOUD"' }, methods.fetch("Bar#relay"))
    end
  end

  def test_runner_carries_a_literal_through_a_call_that_passes_its_block
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def relay: (bool) ?{ () -> void } -> String
          def label: (bool) ?{ () -> void } -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet
            relay(true)
          end

          def relay(loud, &block)
            label(loud, &block)
          end

          def label(loud, &block)
            if block_given?
              "block"
            elsif loud
              "LOUD"
            else
              "quiet"
            end
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(true)" => '"LOUD"' }, methods.fetch("Bar#label"))
      assert_equal({ "(true)" => '"LOUD"' }, methods.fetch("Bar#relay"))
    end
  end

  def test_runner_does_not_record_a_passed_block_as_no_block
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: (^() -> void) -> String
          def relay: (bool) ?{ () -> void } -> String
          def label: (bool) ?{ () -> void } -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet(callback)
            relay(true, &callback)
          end

          def relay(loud, &block)
            label(loud, &block)
          end

          def label(loud, &block)
            if block_given?
              "block"
            elsif loud
              "LOUD"
            else
              "quiet"
            end
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      refute_includes methods.fetch("Bar#label", {}).values, '"LOUD"'
      refute_includes methods.fetch("Bar#relay", {}).values, '"LOUD"'
    end
  end

  # A tuple whose argument is a literal only because the call inside it
  # specialized: `shout` passes `label(true)`, typed `String` until `label` has
  # its entry and `"LOUD"` after.
  def test_runner_grows_a_tuple_from_a_specialized_argument
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def shout: () -> String
          def wrap: (String) -> String
          def label: (bool) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def shout
            wrap(label(true))
          end

          def wrap(text)
            text
          end

          def label(loud)
            if loud
              "LOUD"
            else
              "quiet"
            end
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ '("LOUD")' => '"LOUD"' }, methods.fetch("Bar#wrap"))
    end
  end

  # The fixpoint's termination, which is the whole reason widening exists: every
  # generation folds a longer literal and supplies a tuple never seen before.
  def test_runner_terminates_on_a_body_that_folds_a_longer_literal
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def start: () -> String
          def g: (String) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def start
            g("a")
          end

          def g(s)
            g("\#{s}x")
          end
        end
      RUBY

      methods = Timeout.timeout(60) { Specializations::Runner.run(setup_project) }

      recorded = methods.fetch("Bar#g", {})
      assert_operator recorded.size, :<=, Specializations::Runner::WIDEN_AFTER
      recorded.each_key { |key| assert_operator key.length, :<=, Specializations::Runner::LITERAL_WIDTH }
    end
  end

  # The other divergence, and the one a generation count was hiding: no new tuple
  # is ever supplied — `f(flag)` calls itself with the same `(true)` — yet the
  # return folds one more `x` every generation. The widening of a return that
  # disagrees with the generation before is what stops it, and `String` is the
  # honest answer: the program does not fix this value.
  def test_runner_widens_a_return_that_keeps_growing
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def start: () -> String
          def f: (bool) -> "a"
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def start
            f(true)
          end

          def f(flag)
            if flag
              "\#{f(flag)}x"
            else
              "base"
            end
          end
        end
      RUBY

      methods = Timeout.timeout(120) { Specializations::Runner.run(setup_project) }

      # Nothing recorded is the honest answer: widening took the return back to
      # what the declaration already gives, so there is no specialization to
      # state. Without it the entry was `"axxxxxx"` — one `x` per generation, the
      # value decided by where the loop was cut off.
      assert_empty methods.fetch("Bar#f", {})
    end
  end

  # felixefelip/steep#207. `dup` answers `self`, so the copy starts out as the
  # literal it was made from — and `sub!` changes it in place. What the body
  # records is the value it leaves (felixefelip/steep#209), never the one it
  # was called with.
  def test_runner_records_the_value_a_literal_mutated_in_place_leaves
    in_tmpdir do
      write("sig/mutation.rbs", <<~RBS)
        class Mutation
          def self.chop_bang: (String word) -> String
        end
        class MutationUse
          def self.a: () -> String
          def self.b: () -> String
        end
      RBS
      write("app/mutation.rb", <<~'RUBY')
        class Mutation
          def self.chop_bang(word)
            result = word.dup
            result.sub!(/s\z/, "")
            result
          end
        end

        class MutationUse
          def self.a = Mutation.chop_bang("posts")
          def self.b = Mutation.chop_bang("comments")
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal(
        { '("posts")' => '"post"', '("comments")' => '"comment"' },
        methods.fetch("Mutation.chop_bang")
      )
    end
  end

  # The shape `ActiveSupport::Inflector.apply_inflections` has: the `sub!` is
  # inside the block, `break` included.
  def test_runner_folds_rules_applied_in_order_until_one_matches
    in_tmpdir do
      write("sig/mutation.rbs", <<~RBS)
        class Mutation
          def self.apply: (String word) -> String
        end
        class MutationUse
          def self.a: () -> String
          def self.b: () -> String
        end
      RBS
      write("app/mutation.rb", <<~'RUBY')
        class Mutation
          def self.apply(word)
            result = word.dup
            [[/ies\z/, "y"], [/s\z/, ""]].each { |(rule, replacement)| break if result.sub!(rule, replacement) }
            result
          end
        end

        class MutationUse
          def self.a = Mutation.apply("posts")
          def self.b = Mutation.apply("categories")
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal(
        {
          '("posts")' => '"post"', '("posts") on singleton(::Mutation)' => '"post"',
          '("categories")' => '"category"', '("categories") on singleton(::Mutation)' => '"category"'
        },
        methods.fetch("Mutation.apply")
      )
    end
  end

  def test_runner_records_what_an_early_return_hands_back
    in_tmpdir do
      write("sig/guarded.rbs", <<~RBS)
        class Guarded
          def self.apply: (String word) -> String
          def self.both: (String word) -> String
          def self.either: (String word) -> String
          def self.cased: (String word) -> String
          def self.nilable: (String word, String? name) -> String
          def self.compared: (String word, String other) -> String
          def self.name: () -> String?
          def self.only: (String word) -> String
          def self.lambdas: (String word) -> String
        end
        class GuardedUse
          def self.a: () -> String
          def self.b: () -> String
          def self.c: () -> String
          def self.d: () -> String
          def self.e: () -> String
          def self.f: () -> String
          def self.g: () -> String
          def self.h: () -> String
          def self.i: () -> String
          def self.j: () -> String
        end
      RBS
      write("app/guarded.rb", <<~'RUBY')
        class Guarded
          def self.apply(word)
            result = word.dup
            return result if word.empty? || ["news"].include?(result)

            [[/s\z/, ""]].each { |(rule, replacement)| break if result.sub!(rule, replacement) }
            result
          end

          def self.both(word)
            return "both" if word == "posts" && word == "x"

            word
          end

          def self.either(word)
            return "either" if word == "x" || word == "y"

            word
          end

          def self.cased(word)
            case word
            when "news" then return "N"
            end
            word
          end

          def self.nilable(word, name)
            return "nilable" if name && word == "x"

            word
          end

          def self.compared(word, other)
            return "compared" if other == "a" && word == "x"

            word
          end

          def self.name = ENV["NAME"]

          def self.only(word)
            return word
          end

          def self.lambdas(word)
            check = -> { return "L" if it.empty? }
            check.call(word)
            word
          end
        end

        class GuardedUse
          def self.a = Guarded.apply("posts")
          def self.b = Guarded.apply("news")
          def self.c = Guarded.apply("")
          def self.d = Guarded.both("posts")
          def self.e = Guarded.either("posts")
          def self.f = Guarded.cased("posts")
          def self.g = Guarded.nilable("posts", Guarded.name)
          def self.h = Guarded.compared("posts", Guarded.name.to_s)
          def self.i = Guarded.only("posts")
          def self.j = Guarded.lambdas("posts")
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ '("posts")' => '"post"', '("news")' => '"news"', '("")' => '""' }, unkeyed(methods.fetch("Guarded.apply")))
      assert_equal({ '("posts")' => '"posts"' }, unkeyed(methods.fetch("Guarded.both")))
      assert_equal({ '("posts")' => '"posts"' }, unkeyed(methods.fetch("Guarded.either")))
      assert_equal({ '("posts")' => '"posts"' }, unkeyed(methods.fetch("Guarded.cased")))
      assert_equal(['"posts"'], unkeyed(methods.fetch("Guarded.nilable")).values)
      assert_equal(['"posts"'], unkeyed(methods.fetch("Guarded.compared")).values)
      assert_equal({ '("posts")' => '"posts"' }, unkeyed(methods.fetch("Guarded.only")))
      assert_equal({ '("posts")' => '"posts"' }, unkeyed(methods.fetch("Guarded.lambdas")))
    end
  end

  def test_runner_records_nothing_for_a_literal_mutated_by_rules_it_does_not_know
    in_tmpdir do
      write("sig/mutation.rbs", <<~RBS)
        class Mutation
          def self.rules: () -> Array[[Regexp, String]]
          def self.apply: (String word) -> String
        end
        class MutationUse
          def self.a: () -> String
          def self.b: () -> String
        end
      RBS
      write("app/mutation.rb", <<~'RUBY')
        class Mutation
          def self.rules = [[/s\z/, ""]]

          def self.apply(word)
            result = word.dup
            rules.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
            result
          end
        end

        class MutationUse
          def self.a = Mutation.apply("posts")
          def self.b = Mutation.apply("comments")
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      refute_includes methods.keys, "Mutation.apply"
    end
  end

  # felixefelip/steep#209, item 2: the stateless controls. `sub!` applied to
  # a copy is pinned by the felixefelip/steep#207 test above.
  def test_runner_folds_the_core_calls_an_inflector_rule_is_applied_with
    in_tmpdir do
      write("sig/inflector.rbs", <<~RBS)
        module P3Inflector
          def self.singularize_regexp: (String word) -> String
          def self.singularize_suffix: (String word) -> String
        end
        class P3Use
          def self.regexp_posts: () -> String
          def self.suffix_posts: () -> String
          def self.regexp_comments: () -> String
          def self.suffix_comments: () -> String
        end
      RBS
      write("app/inflector.rb", <<~'RUBY')
        module P3Inflector
          def self.singularize_regexp(word) = word.sub(/s\z/, "")
          def self.singularize_suffix(word) = word.delete_suffix("s")
        end

        class P3Use
          def self.regexp_posts = P3Inflector.singularize_regexp("posts")
          def self.suffix_posts = P3Inflector.singularize_suffix("posts")
          def self.regexp_comments = P3Inflector.singularize_regexp("comments")
          def self.suffix_comments = P3Inflector.singularize_suffix("comments")
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      expected = { '("posts")' => '"post"', '("comments")' => '"comment"' }
      assert_equal expected, methods.fetch("P3Inflector.singularize_regexp")
      assert_equal expected, methods.fetch("P3Inflector.singularize_suffix")
    end
  end

  def test_runner_writes_and_deletes_the_sidecar
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)
      project = setup_project
      runner = Specializations::Runner.new(project)

      runner.write(runner.run)

      assert_predicate runner.output_path, :file?
      store = Specializations.load(project.base_dir)
      assert_equal(
        '"name_delete"',
        store.methods.fetch("Example::Foo#call").fetch("(flag_name: true)")
      )

      Specializations::Runner.new(project).write({})
      refute_predicate runner.output_path, :file?
    end
  end

  # A sidecar entry is TEXT, read back through `RBS::Parser.parse_type`, and a
  # type RBS cannot spell does not survive that round trip — silently, since
  # `singleton_class(::Probe)` parses as the alias `singleton_class`. So what is
  # recorded is what a signature can say.
  def test_runner_records_a_type_a_signature_can_say
    in_tmpdir do
      write("sig/probe.rbs", <<~RBS)
        class Probe
          def self.human_name: (String index) -> String
          def reflect: (bool wrap) -> Array[untyped]
          def call_reflect: () -> Array[untyped]
        end
      RBS
      write("app/probe.rb", <<~RUBY)
        class Probe
          def self.human_name(index) = index

          def reflect(wrap)
            [Probe.singleton_class, wrap]
          end

          def call_reflect = reflect(true)
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)
      recorded = methods.fetch("Probe#reflect").fetch("(true)")

      assert_includes recorded, "::Class"
      refute_match(/singleton_class\(/, recorded)
      # Reads back as the type it says, and stays it.
      parsed = RBS::Parser.parse_type(recorded)
      refute_instance_of RBS::Types::Alias, parsed
      assert_equal parsed.to_s, RBS::Parser.parse_type(parsed.to_s).to_s
    end
  end

  # What that is worth avoiding: the spelling of a type RBS cannot say parses
  # as something else rather than failing.
  def test_a_type_rbs_cannot_say_is_written_as_the_one_it_can
    metaclass = Steep::AST::Types::MetaClass.new(name: RBS::TypeName.parse("::Probe"))
    written = Specializations.rbs_writable(
      Steep::AST::Types::Tuple.new(types: [metaclass, Steep::AST::Types::Literal.new(value: 1)])
    )

    assert_equal "[::Class, 1]", written.to_s
    assert_instance_of RBS::Types::Alias, RBS::Parser.parse_type(metaclass.to_s)
  end

  def test_store_ignores_a_sidecar_from_another_schema_version
    store = Specializations::Store.from_hash(
      { "version" => 99, "methods" => { "Foo#bar" => { "(1)" => "Integer" } } },
      source: "test", base_dir: Pathname("/")
    )

    assert_predicate store, :empty?
  end

  def test_a_call_site_reads_back_the_specialized_return_type
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)
      project = setup_project
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!

      types = body_types(project, current_dir + "app/foo.rb")

      assert_equal '"name_delete"', types.fetch("call_name_action")
      assert_equal '"delete"', types.fetch("call_action")
      assert_equal "::String", types.fetch("call_unknown")
    end
  end

  def test_a_call_site_passing_keywords_to_a_keyword_rest_reads_back_its_branch
    in_tmpdir do
      write("sig/pick.rbs", <<~RBS)
        class P7Plain
        end
        class P7Through
        end
        class P7Pick
          def self.association_class: (**untyped) -> untyped
        end
        class P7Use
          def through: () -> untyped
          def plain: () -> untyped
          def other: () -> untyped
        end
      RBS
      write("app/pick.rb", <<~RUBY)
        class P7Pick
          def self.association_class(**options)
            options[:through] ? P7Through : P7Plain
          end
        end

        class P7Use
          def through = P7Pick.association_class(through: :taggings)
          def plain = P7Pick.association_class
          def other = P7Pick.association_class(dependent: :destroy)
        end
      RUBY
      project = setup_project
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!

      types = body_types(project, current_dir + "app/pick.rb")

      assert_equal "singleton(::P7Through)", types.fetch("through")
      assert_equal "singleton(::P7Plain)", types.fetch("plain")
      assert_equal "singleton(::P7Plain)", types.fetch("other")
    end
  end

  def test_a_call_site_passing_a_hash_literal_reads_back_its_branch
    in_tmpdir do
      write("sig/pick.rbs", <<~RBS)
        class P6Plain
        end
        class P6Through
        end
        class P6Pick
          def self.association_class: (untyped options) -> untyped
        end
        class P6Use
          def through: () -> untyped
          def plain: () -> untyped
          def other: () -> untyped
        end
      RBS
      write("app/pick.rb", <<~RUBY)
        class P6Pick
          def self.association_class(options)
            options[:through] ? P6Through : P6Plain
          end
        end

        class P6Use
          def through = P6Pick.association_class({ through: :posts })
          def plain = P6Pick.association_class({})
          def other = P6Pick.association_class({ dependent: :destroy })
        end
      RUBY
      project = setup_project
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!

      types = body_types(project, current_dir + "app/pick.rb")

      assert_equal "singleton(::P6Through)", types.fetch("through")
      assert_equal "singleton(::P6Plain)", types.fetch("plain")
      assert_equal "singleton(::P6Plain)", types.fetch("other")
    end
  end

  def test_a_call_site_reads_the_declaration_without_a_sidecar
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)

      types = body_types(setup_project, current_dir + "app/foo.rb")

      assert_equal "::String", types.fetch("call_name_action")
    end
  end
end

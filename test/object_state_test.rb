require_relative "test_helper"

# `Klass.new(<fixed values>)` typed as the object it builds, ivars and all
# (felixefelip/steep#205, stage 1).
class ObjectStateTest < Minitest::Test
  include TestHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  RBS = <<~RBS
    class Reflection
      @name: Symbol
      attr_reader name: Symbol
      def initialize: (Symbol name) -> void
      def label: () -> Symbol
    end
    class Pair
      @left: untyped
      def left: () -> untyped
      def initialize: (*untyped) -> void
    end
    class Box
      @value: untyped
      attr_reader value: untyped
      def initialize: (untyped value) -> void
    end
    class Made
      @name: Symbol
      attr_reader name: Symbol
      def self.new: (Symbol name) -> Made
      def initialize: (Symbol name) -> void
    end
    class Base
      @name: Symbol
      attr_reader name: Symbol
    end
    class Sub < Base
      def initialize: (Symbol name) -> void
    end
    class Undeclared
      def name: () -> Symbol
      def initialize: (Symbol name) -> void
    end
    class Renamed
      @name: Symbol
      attr_accessor name: Symbol
      def initialize: (Symbol name) -> void
    end
    module Wrap
    end
    module Ex
    end
    class Ex::Scoped
      @name: Symbol
      attr_reader name: Symbol
      def initialize: (Symbol name) -> void
      def rename: () -> Symbol
    end
    class Defined
      @name: Symbol?
      attr_reader name: Symbol?
      def initialize: (Symbol name) -> void
      def reset: () -> nil
    end
    class Evaled
      @name: Symbol
      attr_reader name: Symbol
      def initialize: (Symbol name) -> void
      def rename: () -> Symbol
    end
  RBS

  RUBY = <<~RUBY
    class Reflection
      attr_reader :name
      def initialize(name)
        @name = name
      end
      def label = :label
    end
    class Pair
      def initialize(left)
        @left = left
      end
      def left = @left
    end
    class Box
      attr_reader :value
      def initialize(value)
        @value = value
      end
    end
    class Made
      attr_reader :name
      def self.new(name) = super(:other)
      def initialize(name)
        @name = name
      end
    end
    class Sub < Base
      def initialize(name)
        @name = name
      end
    end
    class Undeclared
      def name = @name
      def initialize(name)
        @name = name
      end
    end
    class Renamed
      attr_accessor :name
      def initialize(name)
        @name = name
      end
    end
    module Wrap
      class Ex::Scoped
        attr_reader :name
        def initialize(name)
          @name = name
        end
        def rename = @name = :x
      end
    end
    class Defined
      attr_reader :name
      def initialize(name)
        @name = name
      end
      define_method(:reset) { @name = nil }
    end
    class Evaled
      attr_reader :name
      def initialize(name)
        @name = name
      end
    end
    Evaled.class_eval do
      def rename = @name = :x
    end
  RUBY

  # The sidecar `steep check` writes for RUBY: each `initialize` writes the ivar
  # it binds, and nothing else does.
  SIDECAR = [
    ["Reflection", "initialize", "@name"],
    ["Pair", "initialize", "@left"],
    ["Box", "initialize", "@value"],
    ["Made", "initialize", "@name"],
    ["Sub", "initialize", "@name"]
  ].freeze

  def postconditions(rows)
    Steep::Postconditions::Store.from_hash(
      { "postconditions" => rows.map { |klass, method, ivar| { "class" => klass, "method" => method, "effects" => { "may_write" => [ivar] } } } },
      source: "test"
    )
  end

  # The sidecar `sidecar: :inferred` stands for: what the postconditions
  # inferrer reads off RUBY, rather than rows written down here.
  def inferred_postconditions(checker)
    source = parse_ruby(RUBY)
    entries = nil
    with_standard_construction(checker, source) do |construction, typing|
      construction.synthesize(source.node)
      entries = Steep::Postconditions::Inferrer.infer(source, typing, checker)
    end
    Steep::Postconditions::Store.from_hash(YAML.safe_load(Steep::Postconditions::Writer.dump(entries)), source: "test")
  end

  def check(source_text, sidecar: SIDECAR)
    registry = Steep::Project::ConstructorBindingRegistry.new
    registry.ingest_source(RUBY, path_name: "app.rb")

    with_checker({ "app.rbs" => RBS }, with_stdlib: true) do |checker|
      source = parse_ruby(source_text)
      store = sidecar == :inferred ? inferred_postconditions(checker) : postconditions(sidecar)

      with_standard_construction(checker, source, constructor_bindings: registry, postconditions: store) do |construction, typing|
        pair = construction.synthesize(source.node)

        assert_no_error typing
        yield pair
      end
    end
  end

  def state(class_name, ivars)
    Steep::AST::Types::ObjectState.new(
      back_type: parse_type(class_name),
      ivars: ivars.transform_values { |type| parse_type(type) }
    )
  end

  def test_new_with_a_literal_holds_it
    check(<<~'RUBY') do |pair|
      r = Reflection.new(:posts)
    RUBY
      assert_equal state("::Reflection", :@name => ":posts"), pair.context.type_env[:r]
    end
  end

  def test_a_reader_answers_what_the_object_holds
    check(<<~'RUBY') do |pair|
      r = Reflection.new(:posts)
      n = r.name
      other = r.label
    RUBY
      assert_equal parse_type(":posts"), pair.context.type_env[:n]
      assert_equal parse_type("::Symbol"), pair.context.type_env[:other]
    end
  end

  def test_a_def_reader_answers_through_the_constructor_index
    check(<<~'RUBY') do |pair|
      n = Pair.new(:a).left
    RUBY
      assert_equal parse_type(":a"), pair.context.type_env[:n]
    end
  end

  def test_a_state_nests
    check(<<~'RUBY') do |pair|
      n = Box.new(Reflection.new(:posts)).value.name
    RUBY
      assert_equal parse_type(":posts"), pair.context.type_env[:n]
    end
  end

  def test_the_object_is_still_its_class
    check(<<~'RUBY') do |pair|
      # @type var r: Reflection
      r = Reflection.new(:posts)
    RUBY
      assert_equal parse_type("::Reflection"), pair.context.type_env[:r]
    end
  end

  # A String can change under another name (felixefelip/steep#216), and so
  # can an array.
  def test_a_value_that_can_change_does_not_make_a_state
    check(<<~'RUBY') do |pair|
      a = Box.new("posts")
      b = Box.new([:posts])
      # @type var sym: Symbol
      sym = _ = :x
      c = Reflection.new(sym)
    RUBY
      assert_equal parse_type("::Box"), pair.context.type_env[:a]
      assert_equal parse_type("::Box"), pair.context.type_env[:b]
      assert_equal parse_type("::Reflection"), pair.context.type_env[:c]
    end
  end

  def test_one_of_several_fixed_values
    check(<<~'RUBY') do |pair|
      # @type var flag: bool
      flag = _ = true
      r = Reflection.new(flag ? :posts : :comments)
    RUBY
      assert_equal state("::Reflection", :@name => ":posts | :comments"), pair.context.type_env[:r]
    end
  end

  # A `def self.new` answers whatever it likes, and a splat moves what lands
  # where.
  def test_a_new_that_is_not_initialize_or_a_splat
    check(<<~'RUBY') do |pair|
      made = Made.new(:posts)
      # @type var names: Array[Symbol]
      names = [:posts]
      splat = Pair.new(*names)
    RUBY
      assert_equal parse_type("::Made"), pair.context.type_env[:made]
      assert_equal parse_type("::Pair"), pair.context.type_env[:splat]
    end
  end

  def test_an_ivar_another_method_writes_does_not_make_a_state
    check(<<~'RUBY', sidecar: [*SIDECAR, ["Reflection", "rename", "@name"]]) do |pair|
      r = Reflection.new(:posts)
    RUBY
      assert_equal parse_type("::Reflection"), pair.context.type_env[:r]
    end
  end

  # Until `steep check` has written a sidecar, nothing says no other method
  # writes the ivar.
  def test_no_postconditions_yet
    check(<<~'RUBY', sidecar: []) do |pair|
      r = Reflection.new(:posts)
    RUBY
      assert_equal parse_type("::Reflection"), pair.context.type_env[:r]
    end
  end

  # `may_write` only records ivars the RBS declares.
  def test_an_undeclared_ivar_does_not_make_a_state
    check(<<~'RUBY') do |pair|
      r = Undeclared.new(:posts)
    RUBY
      assert_equal parse_type("::Undeclared"), pair.context.type_env[:r]
    end
  end

  # A superclass's methods run on the object too.
  def test_an_ancestor_that_writes_the_ivar
    check(<<~'RUBY') do |pair|
      r = Sub.new(:posts)
    RUBY
      assert_equal state("::Sub", :@name => ":posts"), pair.context.type_env[:r]
    end

    # Only the class's own `initialize` is the bind: a superclass's may run
    # through `super` and write something else.
    [["Base", "reset", "@name"], ["Base", "initialize", "@name"]].each do |writer|
      check(<<~'RUBY', sidecar: [*SIDECAR, writer]) do |pair|
        r = Sub.new(:posts)
      RUBY
        assert_equal parse_type("::Sub"), pair.context.type_env[:r], writer.join("#")
      end
    end
  end

  # felixefelip/steep#219: writes the class makes without a plain `def` — an
  # `attr_accessor`, a `def` in a reopen named by a scoped constant, a
  # `define_method` block, a `class_eval` block — mean the ivar is not fixed.
  def test_writes_without_a_plain_def_do_not_make_a_state
    check(<<~'RUBY', sidecar: :inferred) do |pair|
      fixed = Reflection.new(:posts)
      renamed = Renamed.new(:posts)
      scoped = Ex::Scoped.new(:posts)
      defined = Defined.new(:posts)
      evaled = Evaled.new(:posts)
    RUBY
      assert_equal state("::Reflection", :@name => ":posts"), pair.context.type_env[:fixed]
      assert_equal parse_type("::Renamed"), pair.context.type_env[:renamed]
      assert_equal parse_type("::Ex::Scoped"), pair.context.type_env[:scoped]
      assert_equal parse_type("::Defined"), pair.context.type_env[:defined]
      assert_equal parse_type("::Evaled"), pair.context.type_env[:evaled]
    end
  end
end

require_relative "test_helper"

# An ivar an ancestor's `initialize` binds: inherited, reached through `super`,
# or from an included module (felixefelip/steep#230).
class ObjectStateAncestorsTest < Minitest::Test
  include TestHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  RBS = <<~RBS
    class Macro
      @name: Symbol
      attr_reader name: Symbol
      def initialize: (Symbol name) -> void
    end
    class Inherits < Macro
    end
    class Explicit < Macro
      @options: Symbol
      def initialize: (Symbol name, Symbol options) -> void
    end
    class Swapped < Macro
      def initialize: (Symbol options, Symbol name) -> void
    end
    class Zsuper < Macro
      def initialize: (Symbol name) -> void
    end
    class Grandchild < Zsuper
    end
    module Named
      @name: Symbol
      attr_reader name: Symbol
      def initialize: (Symbol name) -> void
    end
    class Mixed
      include Named
    end
    class Maybe < Macro
      def initialize: (Symbol name) -> void
    end
    class Overwrites < Macro
      def initialize: (Symbol name) -> void
    end
    class Literal < Macro
      def initialize: (Symbol name) -> void
    end
    class Undeclared < Macro
    end
    class Opaque
      @name: Symbol
      attr_reader name: Symbol
      def initialize: (Symbol name) -> void
    end
    class FromOpaque < Opaque
      def initialize: (Symbol name) -> void
    end
    class Shadow < Macro
      def initialize: (Symbol name) -> void
    end
  RBS

  RUBY = <<~RUBY
    class Macro
      attr_reader :name
      def initialize(name)
        @name = name
      end
    end
    class Inherits < Macro
    end
    class Explicit < Macro
      def initialize(name, options)
        super(name)
        @options = options
      end
    end
    class Swapped < Macro
      def initialize(options, name)
        super(name)
      end
    end
    class Zsuper < Macro
      def initialize(name)
        super
      end
    end
    class Grandchild < Zsuper
    end
    module Named
      attr_reader :name
      def initialize(name)
        @name = name
      end
    end
    class Mixed
      include Named
    end
    class Maybe < Macro
      def initialize(name)
        super if name
      end
    end
    class Overwrites < Macro
      def initialize(name)
        super
        @name = :other
      end
    end
    class Literal < Macro
      def initialize(name)
        super(:fixed)
      end
    end
    class Undeclared < Macro
      def initialize(name)
        @name = :undeclared
      end
    end
    class FromOpaque < Opaque
      def initialize(name)
        @name = name
        super
      end
    end
    class Shadow < Macro
      def initialize(name)
        @name = name
      end
    end
  RUBY

  # Each `initialize` writes the ivars it assigns, and nothing else does.
  SIDECAR = [
    ["Macro", "initialize", "@name"],
    ["Explicit", "initialize", "@options"],
    ["Named", "initialize", "@name"],
    ["Overwrites", "initialize", "@name"],
    ["Undeclared", "initialize", "@name"],
    ["FromOpaque", "initialize", "@name"],
    ["Shadow", "initialize", "@name"]
  ].freeze

  def postconditions(rows)
    Steep::Postconditions::Store.from_hash(
      { "postconditions" => rows.map { |klass, method, ivar| { "class" => klass, "method" => method, "effects" => { "may_write" => [ivar] } } } },
      source: "test"
    )
  end

  def check(source_text, sidecar: SIDECAR)
    registry = Steep::Project::ConstructorBindingRegistry.new
    registry.ingest_source(RUBY, path_name: "app.rb")

    with_checker({ "app.rbs" => RBS }, with_stdlib: true) do |checker|
      source = parse_ruby(source_text)

      with_standard_construction(checker, source, constructor_bindings: registry, postconditions: postconditions(sidecar)) do |construction, typing|
        pair = construction.synthesize(source.node)

        assert_no_error typing
        yield pair.context.type_env
      end
    end
  end

  def assert_name(expected, klass, args = ":posts")
    check("n = #{klass}.new(#{args}).name\n") do |env|
      assert_equal parse_type(expected), env[:n], klass
    end
  end

  def test_an_inherited_initialize_binds
    assert_name ":posts", "Inherits"
  end

  def test_super_with_arguments_hands_the_binding_on
    check("r = Explicit.new(:posts, :opts)\n") do |env|
      state = Steep::AST::Types::ObjectState.new(
        back_type: parse_type("::Explicit"),
        ivars: { :@name => parse_type(":posts"), :@options => parse_type(":opts") }
      )
      assert_equal state, env[:r]
    end
  end

  def test_super_maps_the_position_it_passes
    assert_name ":posts", "Swapped", ":opts, :posts"
  end

  def test_a_bare_super_forwards_every_argument
    assert_name ":posts", "Zsuper"
  end

  def test_the_chain_reaches_through_an_inherited_level
    assert_name ":posts", "Grandchild"
  end

  def test_a_module_initialize_binds
    assert_name ":posts", "Mixed"
  end

  def test_a_super_that_may_not_run_binds_nothing
    assert_name "::Symbol", "Maybe"
  end

  def test_a_write_after_super_binds_nothing
    assert_name "::Symbol", "Overwrites"
  end

  def test_a_literal_passed_to_super_is_not_the_argument
    assert_name "::Symbol", "Literal"
  end

  # The RBS places no `initialize` in `Undeclared`, so the call resolves to
  # `Macro#initialize`; the one Ruby runs is `Undeclared`'s.
  def test_an_initialize_the_rbs_does_not_place_binds_nothing
    assert_name "::Symbol", "Undeclared"
  end

  # `Opaque` has no source: its `initialize` may write `@name` after this one.
  def test_a_super_into_an_initialize_without_source_binds_nothing
    assert_name "::Symbol", "FromOpaque"
  end

  # `Macro#initialize` writes `@name` too, but never runs on a `Shadow`.
  def test_an_ancestor_initialize_that_does_not_run_does_not_count
    assert_name ":posts", "Shadow"
  end

  # Another method of an ancestor writing the ivar still counts.
  def test_an_ancestor_method_writing_the_ivar_binds_nothing
    sidecar = SIDECAR + [["Macro", "rename", "@name"]]
    check("n = Inherits.new(:posts).name\n", sidecar: sidecar) do |env|
      assert_equal parse_type("::Symbol"), env[:n]
    end
  end
end

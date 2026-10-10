require_relative "test_helper"

# A state changed after `new`, followed through the one local that owns the
# object (felixefelip/steep#205, stage 2).
class ObjectStateHeldTest < Minitest::Test
  include TestHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  RBS = <<~RBS
    class Reflection
      @name: Symbol
      @label: Symbol
      attr_reader name: Symbol
      attr_accessor label: Symbol
      def initialize: (Symbol name, ?Symbol label) -> void
      def current_label: () -> Symbol
      def rename: (Symbol to) -> Symbol
      def rename_if: (Symbol to, bool flag) -> Symbol?
      def refresh: () -> Symbol
      def rename_then_clear: (Symbol to) -> Symbol
      def clear: () -> Symbol
      def shout: () -> Symbol
      def register: () -> void
    end
    class Reflection
      class AfterRename
        attr_reader name: :articles | :replies
      end
    end
    class Fixed
      @name: Symbol
      attr_reader name: Symbol
      def initialize: (Symbol name) -> void
    end
    class Base
      @name: Symbol
      @label: Symbol
      attr_reader name: Symbol
      attr_reader label: Symbol
      def initialize: (Symbol name, Symbol label) -> void
      def rename: (Symbol to) -> void
      def touch: () -> void
    end
    class Child < Base
      def touch: () -> void
    end
    class Norm
      @name: Symbol
      attr_reader name: Symbol
      def initialize: (Symbol name) -> void
      def normalize: () -> Symbol
    end
    class Writer
      def self.take: (untyped) -> void
      def self.take_renamed: (Reflection & Reflection::AfterRename) -> void
    end
    class Probe
      def run: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class Reflection
      attr_reader :name
      attr_accessor :label
      def initialize(name, label = :none)
        @name = name
        @label = label
      end
      def current_label = @label
      def rename(to)
        @name = to
      end
      def rename_if(to, flag)
        @name = to if flag
      end
      def refresh = rename(:fresh)
      def rename_then_clear(to)
        @name = to
        clear
      end
      def clear = @name = :cleared
      def shout = name
      def register = Writer.take(self)
    end
    class Fixed
      attr_reader :name
      def initialize(name)
        @name = name
      end
    end
    class Base
      attr_reader :name, :label
      def initialize(name, label)
        @name = name
        @label = label
      end
      def rename(to)
        @name = to
        touch
      end
      def touch = nil
    end
    class Child < Base
      def touch = @label = :touched
    end
    class Norm
      attr_reader :name
      def initialize(name)
        @name = name
        normalize
      end
      def normalize = @name = :normal
    end
  RUBY

  SIDECAR = [
    ["Reflection", "initialize", "@name"],
    ["Reflection", "initialize", "@label"],
    ["Reflection", "rename", "@name"],
    ["Reflection", "rename_if", "@name"],
    ["Reflection", "refresh", "@name"],
    ["Reflection", "rename_then_clear", "@name"],
    ["Reflection", "clear", "@name"],
    ["Reflection", "label=", "@label"],
    ["Fixed", "initialize", "@name"],
    ["Base", "initialize", "@name"],
    ["Base", "initialize", "@label"],
    ["Base", "rename", "@name"],
    ["Child", "touch", "@label"],
    ["Norm", "initialize", "@name"],
    ["Norm", "normalize", "@name"]
  ].freeze

  def postconditions(unconditional = {})
    rows = SIDECAR.map do |klass, method, ivar|
      row = { "class" => klass, "method" => method, "effects" => { "may_write" => [ivar] } }
      (marker = unconditional[[klass, method]]) ? row.merge("unconditional" => { "self" => marker }) : row
    end
    Steep::Postconditions::Store.from_hash({ "postconditions" => rows }, source: "test")
  end

  # `rename` as rbs_infer's marker for it reads back.
  RENAME_MARKER = { ["Reflection", "rename"] => "::Reflection & ::Reflection::AfterRename" }.freeze

  # The type of the last statement of `body`, checked as `Probe#run`.
  def last_value(body, postconditions: self.postconditions)
    registry = Steep::Project::ConstructorBindingRegistry.new
    registry.ingest_source(RUBY, path_name: "app.rb")
    source_text = "class Probe\n  def run\n#{body}\n  end\nend\n"

    with_checker({ "app.rbs" => RBS }, with_stdlib: true) do |checker|
      source = parse_ruby(source_text)

      with_standard_construction(checker, source, constructor_bindings: registry, postconditions: postconditions) do |construction, typing|
        construction.synthesize(source.node)
        assert_no_error typing

        statements = def_body(source.node)
        return typing.type_of(node: statements.type == :begin ? statements.children.last : statements).to_s
      end
    end
  end

  def def_body(node)
    return node.children[2] if node.type == :def

    node.children.each do |child|
      next unless child.is_a?(Parser::AST::Node)

      found = def_body(child) and return found
    end
    nil
  end

  def test_a_method_that_binds_the_ivar_moves_it
    assert_equal ":articles", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      r.rename(:articles)
      r.name
    RUBY
  end

  def test_the_last_call_wins
    assert_equal ":replies", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      r.rename(:articles)
      r.rename(:replies)
      r.name
    RUBY
  end

  def test_a_read_before_the_change_is_not_reused
    assert_equal ":articles", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      before = r.name
      r.rename(:articles)
      r.name
    RUBY
  end

  def test_an_attr_writer_binds_its_argument
    assert_equal ":x", last_value(<<~RUBY)
      r = Reflection.new(:posts, :draft)
      r.label = :x
      r.current_label
    RUBY
  end

  def test_an_attr_writer_and_the_reader_cache_agree
    assert_equal ":x", last_value(<<~RUBY)
      r = Reflection.new(:posts, :draft)
      r.label = :x
      r.label
    RUBY
  end

  def test_a_binding_a_method_called_on_self_may_overwrite
    assert_equal "::Symbol", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      r.rename_then_clear(:articles)
      r.name
    RUBY
  end

  # `may_write` is closed in the class that defines `rename`, which calls
  # `Base#touch`; on a `Child` it runs `Child#touch`.
  def test_a_method_called_on_self_that_a_subclass_overrides
    assert_equal "::Symbol", last_value(<<~RUBY)
      c = Child.new(:a, :b)
      c.rename(:x)
      c.label
    RUBY
  end

  def test_an_initialize_that_rewrites_what_it_binds
    assert_equal "::Symbol", last_value(<<~RUBY)
      n = Norm.new(:posts)
      n.name
    RUBY
  end

  # Until `steep check` has written a sidecar, nothing says what any method
  # writes.
  def test_no_postconditions_yet
    empty = Steep::Postconditions::Store.empty
    assert_equal "::Symbol", last_value(<<~RUBY, postconditions: empty)
      r = Reflection.new(:posts)
      r.rename(:articles)
      r.name
    RUBY
  end

  def test_a_call_that_does_not_write_keeps_the_state
    assert_equal ":posts", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      r.shout
      r.label = :x
      r.name
    RUBY
  end

  def test_a_write_that_may_not_happen
    assert_equal "::Symbol", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      r.rename_if(:articles, true)
      r.name
    RUBY
  end

  def test_a_write_through_a_method_called_on_self
    assert_equal "::Symbol", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      r.refresh
      r.name
    RUBY
  end

  def test_a_method_that_hands_self_on
    assert_equal "::Symbol", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      r.register
      r.name
    RUBY
  end

  def test_a_method_with_no_body_to_read
    assert_equal "::Symbol", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      r.frozen?
      r.name
    RUBY
  end

  def test_a_value_that_can_change_is_not_bound
    assert_equal "::Symbol", last_value(<<~RUBY)
      # @type var to: Symbol
      to = _ = :x
      r = Reflection.new(:posts)
      r.rename(to)
      r.name
    RUBY
  end

  def test_handed_on
    assert_equal "::Symbol", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      Writer.take(r)
      r.name
    RUBY
  end

  def test_a_fixed_ivar_survives_being_handed_on
    assert_equal ":posts", last_value(<<~RUBY)
      f = Fixed.new(:posts)
      Writer.take(f)
      f.name
    RUBY
  end

  def test_a_second_name
    assert_equal "::Symbol", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      other = r
      other.name
    RUBY
  end

  def test_a_marker_the_call_leaves_is_what_the_state_is_written_as
    assert_equal ":articles", last_value(<<~RUBY, postconditions: postconditions(RENAME_MARKER))
      r = Reflection.new(:posts)
      r.rename(:articles)
      r.name
    RUBY

    assert_equal "(:articles | :replies)", last_value(<<~RUBY, postconditions: postconditions(RENAME_MARKER))
      r = Reflection.new(:posts)
      r.rename(:articles)
      Writer.take_renamed(r)
      r.name
    RUBY
  end

  def test_one_of_two_states
    assert_equal ":replies", last_value(<<~RUBY)
      # @type var flag: bool
      flag = _ = true
      r = Reflection.new(:posts)
      r.rename(:articles) if flag
      r.rename(:replies)
      r.name
    RUBY
  end

  def test_a_state_returned_as_self
    assert_equal "::Reflection", last_value(<<~RUBY)
      r = Reflection.new(:posts)
      r.itself
    RUBY
  end

  def test_not_held_by_a_local
    assert_equal "::Symbol", last_value(<<~RUBY)
      Reflection.new(:posts).name
    RUBY
  end
end

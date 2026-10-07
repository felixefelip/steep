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
      attr_reader name: Symbol
      def initialize: (Symbol name) -> void
      def label: () -> Symbol
    end
    class Pair
      def left: () -> untyped
      def initialize: (untyped left) -> void
    end
    class Box
      attr_reader value: untyped
      def initialize: (untyped value) -> void
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
  RUBY

  def check(source_text, project_sources: [RUBY])
    registry = Steep::Project::ConstructorBindingRegistry.new
    project_sources.each_with_index { |source, index| registry.ingest_source(source, path_name: "app#{index}.rb") }

    with_checker({ "app.rbs" => RBS }, with_stdlib: true) do |checker|
      source = parse_ruby(source_text)

      with_standard_construction(checker, source, constructor_bindings: registry) do |construction, typing|
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

  def test_an_ivar_written_elsewhere_does_not_make_a_state
    rename = "class Reflection; def rename(to) = @name = to; end"

    check(<<~'RUBY', project_sources: [RUBY, rename]) do |pair|
      r = Reflection.new(:posts)
    RUBY
      assert_equal parse_type("::Reflection"), pair.context.type_env[:r]
    end
  end
end

require_relative "test_helper"

# Which ivars `Klass.new(…)` fixes for the object's whole life
# (felixefelip/steep#205, stage 1), over every source the project has.
class ImmutableIvarBindingsTest < Minitest::Test
  Registry = Steep::Project::ConstructorBindingRegistry

  def registry(*sources)
    Registry.new.tap do |registry|
      sources.each_with_index { |source, index| registry.ingest_source(source, path_name: "source#{index}.rb") }
    end
  end

  REFLECTION = <<~RUBY
    class Example83
      class Reflection
        attr_reader :name

        def initialize(name)
          @name = name
        end
      end
    end
  RUBY

  def test_an_ivar_bound_in_initialize_and_written_nowhere_else
    assert_equal({ :@name => 0 }, registry(REFLECTION).immutable_ivar_bindings_for("::Example83::Reflection"))
  end

  def test_by_position_and_from_an_optional
    bindings = registry(<<~RUBY).immutable_ivar_bindings_for("Pair")
      class Pair
        def initialize(left, right = :none)
          @left = left
          @right = right
          @cache = {}
        end
      end
    RUBY

    assert_equal({ :@left => 0, :@right => 1 }, bindings)
  end

  def test_written_by_another_method
    bindings = registry(REFLECTION, <<~RUBY).immutable_ivar_bindings_for("Example83::Reflection")
      class Example83
        class Reflection
          def rename(to) = @name = to
        end
      end
    RUBY

    assert_equal({}, bindings)
  end

  def test_written_by_an_attr_writer_or_accessor
    %w[attr_writer attr_accessor].each do |macro|
      bindings = registry(REFLECTION, "class Example83::Reflection; #{macro} :name; end")
                   .immutable_ivar_bindings_for("Example83::Reflection")

      assert_equal({}, bindings, macro)
    end
  end

  def test_written_twice_in_initialize_or_from_something_else
    bindings = registry(<<~RUBY).immutable_ivar_bindings_for("Box")
      class Box
        def initialize(a, b)
          @a = a
          @a = b if b
          @b = b.to_s
        end
      end
    RUBY

    assert_equal({}, bindings)
  end

  def test_written_in_a_block_that_may_run_on_an_instance
    bindings = registry(REFLECTION, <<~RUBY).immutable_ivar_bindings_for("Example83::Reflection")
      class Example83
        class Reflection
          define_method(:reset) { @name = nil }
        end
      end
    RUBY

    assert_equal({}, bindings)
  end

  def test_written_in_a_class_eval_block_from_outside
    bindings = registry(REFLECTION, <<~RUBY).immutable_ivar_bindings_for("Example83::Reflection")
      class Example83
        Reflection.class_eval do
          def reset = @name = nil
        end
      end
    RUBY

    assert_equal({}, bindings)
  end

  def test_written_by_instance_variable_set_or_instance_eval
    [
      "Example83::Reflection.new(:a).instance_variable_set(:@name, :b)",
      "Example83::Reflection.new(:a).send(:instance_variable_set, :@name, :b)",
      "Example83::Reflection.new(:a).instance_eval { @name = :b }",
      "obj = Object.new; def obj.x = @name = 1"
    ].each do |writer|
      bindings = registry(REFLECTION, writer).immutable_ivar_bindings_for("Example83::Reflection")

      assert_equal({}, bindings, writer)
    end
  end

  # `base.extend(M)` gives one object M's methods: what it can write is what
  # a module's instance methods write.
  def test_an_extended_object_gets_what_a_module_writes
    writer = <<~RUBY
      module Renames
        def rename(to) = @name = to
      end
      module Hook
        def self.included(base) = base.extend(Renames)
      end
    RUBY
    assert_equal({}, registry(REFLECTION, writer).immutable_ivar_bindings_for("Example83::Reflection"))

    harmless = <<~RUBY
      module Counts
        def bump = @count = 1
      end
      module Hook
        def self.included(base) = base.extend(Counts)
      end
      class Example83
        extend Counts
      end
    RUBY
    assert_equal({ :@name => 0 }, registry(REFLECTION, harmless).immutable_ivar_bindings_for("Example83::Reflection"))
  end

  def test_extend_inside_an_instance_method_extends_that_instance
    writer = <<~RUBY
      module Renames
        def rename(to) = @name = to
      end
      class Other
        def adopt = extend(Renames)
      end
    RUBY
    assert_equal({}, registry(REFLECTION, writer).immutable_ivar_bindings_for("Example83::Reflection"))
  end

  def test_an_ivar_name_this_cannot_read_writes_everything
    bindings = registry(REFLECTION, "def poke(o, name) = o.instance_variable_set(name, 1)")
                 .immutable_ivar_bindings_for("Example83::Reflection")

    assert_equal({}, bindings)
  end

  def test_a_source_that_does_not_parse_writes_everything
    assert_equal({}, registry(REFLECTION, "class (").immutable_ivar_bindings_for("Example83::Reflection"))
    assert_equal({ :@name => 0 }, registry(REFLECTION, "# nothing").immutable_ivar_bindings_for("Example83::Reflection"))
  end

  def test_a_method_on_every_object_writes_on_this_one
    bindings = registry(REFLECTION, "class Object; def clear! = @name = nil; end")
                 .immutable_ivar_bindings_for("Example83::Reflection")

    assert_equal({}, bindings)
  end

  # Code this index does not attribute to the class may write.
  def test_a_superclass_or_a_mixin_answers_nothing
    assert_equal({}, registry("class Base; end\nclass Sub < Base; def initialize(a) = @a = a; end").immutable_ivar_bindings_for("Sub"))
    assert_equal({}, registry("class Mixed; include Comparable; def initialize(a) = @a = a; end").immutable_ivar_bindings_for("Mixed"))
    assert_equal({}, registry("class Opened; def initialize(a) = @a = a; end\nOpened.prepend(Module.new)").immutable_ivar_bindings_for("Opened"))
  end

  def test_two_initializers_answer_nothing
    bindings = registry(REFLECTION, "class Example83::Reflection; def initialize(other) = @name = other; end")
                 .immutable_ivar_bindings_for("Example83::Reflection")

    assert_equal({}, bindings)
  end

  # A class ivar is not an instance's.
  def test_writes_on_the_class_itself_do_not_count
    bindings = registry(REFLECTION, <<~RUBY).immutable_ivar_bindings_for("Example83::Reflection")
      class Example83
        class Reflection
          @name = :class_level
          def self.memo = @name ||= :x
          class << self
            def reset = @name = nil
          end
        end
      end
    RUBY

    assert_equal({ :@name => 0 }, bindings)
  end
end

require_relative "test_helper"

# Which ivars `Klass.new(…)` leaves holding one of its arguments
# (felixefelip/steep#205, stage 1), over every source the project has.
# Whether anything writes them afterwards is `ObjectStates`' question.
class IvarBindingsTest < Minitest::Test
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

  def test_an_ivar_bound_in_initialize
    assert_equal({ :@name => 0 }, registry(REFLECTION).ivar_bindings_for("::Example83::Reflection"))
  end

  def test_by_position_and_from_an_optional
    bindings = registry(<<~RUBY).ivar_bindings_for("Pair")
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

  def test_written_twice_in_initialize_or_from_something_else
    bindings = registry(<<~RUBY).ivar_bindings_for("Box")
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

  # The slot in the parameter list is the argument's position at the call only
  # up to the first parameter whose position depends on how many are passed.
  def test_a_parameter_whose_position_depends_on_the_call
    bindings = registry(<<~RUBY).ivar_bindings_for("P")
      class P
        def initialize(a, b = 1, c)
          @a = a
          @b = b
          @c = c
        end
      end
    RUBY
    assert_equal({ :@a => 0 }, bindings)

    bindings = registry(<<~RUBY).ivar_bindings_for("S")
      class S
        def initialize(a, *rest, d)
          @a = a
          @d = d
        end
      end
    RUBY
    assert_equal({ :@a => 0 }, bindings)

    bindings = registry(<<~RUBY).ivar_bindings_for("Q")
      class Q
        def initialize(a, b = 1, *rest)
          @a = a
          @b = b
        end
      end
    RUBY
    assert_equal({ :@a => 0, :@b => 1 }, bindings)
  end

  def test_a_parameter_reassigned_before_the_bind
    %w[name\ =\ :other name\ ||=\ :other name\ +=\ 1 name,\ x\ =\ :a,\ :b].each do |reassign|
      bindings = registry(<<~RUBY).ivar_bindings_for("R")
        class R
          def initialize(name)
            #{reassign}
            @name = name
          end
        end
      RUBY

      assert_equal({}, bindings, reassign)
    end
  end

  # `return` before the bind leaves the ivar nil.
  def test_an_initialize_that_may_return_before_the_bind
    bindings = registry(<<~RUBY).ivar_bindings_for("R")
      class R
        def initialize(name, skip)
          return if skip
          @name = name
        end
      end
    RUBY

    assert_equal({}, bindings)
  end

  # Which one runs is a question of load order.
  def test_two_initializers_answer_nothing
    reopen = "class Example83::Reflection; def initialize(other) = @name = other; end"
    assert_equal({}, registry(REFLECTION, reopen).ivar_bindings_for("Example83::Reflection"))

    hidden = "class Example83::Reflection\n  private def initialize(other) = @name = other\nend"
    assert_equal({}, registry(REFLECTION, hidden).ivar_bindings_for("Example83::Reflection"))
  end

  # `class Ex::Reflection` inside `module Wrap` reopens whichever `Ex` resolves
  # to from there, so which class its `initialize` builds is not known.
  def test_an_initialize_in_a_reopen_that_may_name_two_classes
    bindings = registry("module Wrap\n  class Ex::Reflection\n    def initialize(name) = @name = name\n  end\nend")

    assert_equal({}, bindings.ivar_bindings_for("Ex::Reflection"))
    assert_equal({}, bindings.ivar_bindings_for("Wrap::Ex::Reflection"))
  end

  # What a `super` in `initialize` hands on, by call-site position
  # (felixefelip/steep#230).
  def test_what_super_hands_on
    super_args = ->(body, params = "name, options") do
      registry("class S < B\n  def initialize(#{params})\n#{body}\n  end\nend").initializers_for("S").first.super_args
    end

    assert_nil super_args.("@name = name")
    assert_equal [1, 0], super_args.("super(options, name)")
    assert_equal [0, 1], super_args.("super")
    assert_equal [nil, 0], super_args.("super(:fixed, name)")
    assert_equal [0], super_args.("super(name, *rest)")
    assert_equal [nil, 1], super_args.("name = name.to_s\nsuper")
    assert_equal :opaque, super_args.("super if name")
    assert_equal :opaque, super_args.("super\nsuper")
    assert_equal :opaque, super_args.("return if name\nsuper")
  end

  def test_a_module_initialize_is_recorded
    initializers = registry("module Named\n  def initialize(name) = @name = name\nend").initializers_for("Named")

    assert_equal [{ :@name => 0 }], initializers.map(&:bindings)
    assert_equal [Set[:@name]], initializers.map(&:writes)
  end
end

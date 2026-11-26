require_relative "test_helper"
require_relative "specializations_project_helper"

class ClassReachedByValueTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RUBY = <<~'RUBY'
    class Store
      def initialize
        @backend = {}
      end

      def [](key) = @backend[key]

      def []=(key, value)
        @backend[key] = value
      end
    end

    class Base
      def self.inherited(subclass)
        super
        subclass.instance_variable_set(:@cache, %{born})
      end

      def self.compute(name)
        found = @cache[name]
        return found if found

        value = "X#{name}"
    %{store}
        value
      end

      def self.peek(name) = @cache[name]
      def self.wipe = @cache = {}

      def computed = self.class.compute("a")
    end

    class Reflection
      def initialize(owner)
        @owner = owner
      end

      def klass = @owner.send(:compute, "a")
      def clear = @owner.wipe
      def owner = @owner
    end

    class Lookup
      def self.first_klass(reflections) = reflections.fetch(0).klass
    end

    class Post < Base
    end

    class App
      def self.run
    %{run}
      end
    end
  RUBY

  RBS = <<~RBS
    class Store
      @backend: Hash[untyped, untyped]
      def initialize: () -> void
      def []: (untyped key) -> untyped
      def []=: (untyped key, untyped value) -> untyped
    end
    class Base
      def self.inherited: (untyped subclass) -> untyped
      def self.compute: (String name) -> untyped
      def self.peek: (String name) -> untyped
      def self.wipe: () -> untyped
      def computed: () -> untyped
    end
    class Reflection
      @owner: singleton(Post)
      def initialize: (singleton(Post) owner) -> void
      def klass: () -> untyped
      def clear: () -> untyped
      def owner: () -> singleton(Post)
    end
    class Lookup
      def self.first_klass: (Array[Reflection] reflections) -> untyped
    end
    class Post < Base
    end
    class App
      def self.run: () -> untyped
    end
    class Other
      def self.compute: (untyped name) -> untyped
      def self.computed: () -> untyped
    end
  RBS

  def declarations(run, other: "", born: "{}", store: "    @cache[name] = value")
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", format(RUBY, run: run, born: born, store: store))
      write("app/other.rb", "class Other\n  def self.compute(name) = name\n#{other}end\n")
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.declarations
    end
  end

  def test_a_class_held_in_an_ivar_of_the_receiver_carries_its_state
    found = declarations("    Reflection.new(Post).klass")

    assert_equal '"Xa"', found["Reflection#klass"]
  end

  def test_an_instance_carries_its_class_s_state
    found = declarations("    Post.new.computed")

    assert_equal '"Xa"', found["Base#computed"]
  end

  def test_a_class_held_inside_an_argument_carries_its_state
    found = declarations("    Lookup.first_klass([Reflection.new(Post)])")

    assert_equal '"Xa"', found["Lookup.first_klass"]
  end

  def test_a_namesake_called_outside_any_method_does_not_store_into_the_cache
    found = declarations("    Reflection.new(Post).klass", other: "end\nOther.compute(1)\n[Other].each { |other| other.compute(2) }\nclass Other\n")

    assert_equal '"Xa"', found["Reflection#klass"]
  end

  def test_a_namesake_s_method_object_does_not_store_into_the_cache
    found = declarations("    Reflection.new(Post).klass", other: "  def self.computed = method(:compute).call(3)\n")

    assert_equal '"Xa"', found["Reflection#klass"]
  end

  def test_an_object_the_hook_builds_carries_its_state_too
    found = declarations("    Reflection.new(Post).klass", other: "  def self.computed = method(:compute).call(3)\n", born: "Store.new")

    assert_equal '"Xa"', found["Reflection#klass"]
  end

  def test_a_class_cleared_through_a_holder_is_read_as_cleared
    found = declarations("    Post.compute(\"a\")\n    Reflection.new(Post).clear\n    Post.peek(\"a\")")

    assert_equal "nil", found["Base.peek"]
  end

  def test_a_store_inside_a_block_leaves_the_state_to_calls_that_cannot_run_it
    found = declarations("    reflection = Reflection.new(Post)\n    reflection.owner\n    reflection.klass", born: "Store.new", store: "    [name].each { |key| @cache[key] = value }")

    assert_equal '"Xa"', found["Reflection#klass"]
  end
end

require_relative "test_helper"
require_relative "specializations_project_helper"

class ClassReachedByValueTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RUBY = <<~'RUBY'
    class Base
      def self.inherited(subclass)
        super
        subclass.instance_variable_set(:@cache, {})
      end

      def self.compute(name)
        found = @cache[name]
        return found if found

        value = "X#{name}"
        @cache[name] = value
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
    end
    class Lookup
      def self.first_klass: (Array[Reflection] reflections) -> untyped
    end
    class Post < Base
    end
    class App
      def self.run: () -> untyped
    end
  RBS

  def declarations(run)
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", format(RUBY, run: run))
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

  def test_a_class_cleared_through_a_holder_is_read_as_cleared
    found = declarations("    Post.compute(\"a\")\n    Reflection.new(Post).clear\n    Post.peek(\"a\")")

    assert_equal "nil", found["Base.peek"]
  end
end

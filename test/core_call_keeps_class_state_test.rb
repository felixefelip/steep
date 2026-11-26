require_relative "test_helper"
require_relative "specializations_project_helper"

class CoreCallKeepsClassStateTest < Minitest::Test
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
        subclass.instance_variable_set(:@cache, Store.new)
      end

      def self.compute(name)
        found = @cache[name]
        return found if found

        value = "X#{name}"
        @cache[name] = value
        value
      end

      def self.generated
        @generated ||= const_set(:Generated, Module.new)
      end
    %{hook}
    end

    class Reflection
      def initialize(owner)
        @owner = owner
      end

      def klass = @owner.send(:compute, "a")
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
      def self.generated: () -> Module
      def self.const_added: (Symbol name) -> untyped
      def self.to_str: () -> String
    end
    class Reflection
      @owner: singleton(Post)
      def initialize: (singleton(Post) owner) -> void
      def klass: () -> untyped
    end
    class Post < Base
    end
    class App
      def self.run: () -> untyped
    end
  RBS

  def declarations(run, hook: "")
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", format(RUBY, run: run, hook: hook))
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.declarations
    end
  end

  def test_a_constant_set_on_the_class_keeps_its_cache
    found = declarations("    Post.const_set(:Gen, Module.new)\n    Reflection.new(Post).klass")

    assert_equal '"Xa"', found["Reflection#klass"]
  end

  def test_a_method_setting_a_constant_on_its_class_keeps_its_cache
    found = declarations("    Post.generated\n    Reflection.new(Post).klass")

    assert_equal '"Xa"', found["Reflection#klass"]
  end

  def test_a_const_added_the_project_writes_may_change_the_cache
    found = declarations("    Post.const_set(:Gen, Module.new)\n    Reflection.new(Post).klass", hook: '  def self.const_added(name) = @cache["a"] = "Y"')

    refute_equal '"Xa"', found["Reflection#klass"]
  end

  def test_a_class_handed_to_a_reflection_keeps_its_cache
    found = declarations("    Base.equal?(Post)\n    Reflection.new(Post).klass")

    assert_equal '"Xa"', found["Reflection#klass"]
  end

  def test_a_to_str_the_project_writes_may_change_the_cache_of_a_class_handed_to_a_reflection
    found = declarations("    Base.respond_to?(Post)\n    Reflection.new(Post).klass", hook: '  def self.to_str = @cache["a"] = "Y"')

    refute_equal '"Xa"', found["Reflection#klass"]
  end
end

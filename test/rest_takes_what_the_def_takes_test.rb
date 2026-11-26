require_relative "test_helper"
require_relative "specializations_project_helper"

class RestTakesWhatTheDefTakesTest < Minitest::Test
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

    module Hooked
      def self.hooked(base) = base.poison
    end

    module Quiet
      def self.hooked(base) = nil
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

      def self.poison = @cache["a"] = "Y"

      def self.attach(*mods)
        mods.each { |mod| mod.hooked(self) }
        self
      end
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
        Post.attach(%{attached})
        Reflection.new(Post).klass
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
    module Hooked
      def self.hooked: (singleton(Base) base) -> untyped
    end
    module Quiet
      def self.hooked: (singleton(Base) base) -> untyped
    end
    class Base
      def self.inherited: (untyped subclass) -> untyped
      def self.compute: (String name) -> untyped
      def self.poison: () -> untyped
      def self.attach: (singleton(Quiet) | singleton(Hooked) first, *(singleton(Quiet) | singleton(Hooked)) rest) -> untyped
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

  def declarations(attached)
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", format(RUBY, attached: attached))
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.declarations
    end
  end

  def test_an_argument_a_required_slot_of_the_overload_takes_lands_in_the_rest
    assert_equal '"Xa"', declarations("Quiet")["Reflection#klass"]
  end

  def test_a_rest_holds_every_argument_it_takes
    refute_equal '"Xa"', declarations("Quiet, Hooked")["Reflection#klass"]
  end
end

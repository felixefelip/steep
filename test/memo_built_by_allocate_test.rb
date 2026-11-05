require_relative "test_helper"
require_relative "specializations_project_helper"

class MemoBuiltByAllocateTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class K
    end
    class Main
      self.@main: Main?
      @name: Symbol?
      @locals: Hash[Symbol, K]?
      def self.current: () -> Main
      def initialize: () -> void
      def name: () -> Symbol?
      def get: (Symbol key) -> K?
    end
    class Written
      self.@main: Written?
      @locals: Hash[Symbol, K]?
      def self.current: () -> Written
      def get: (Symbol key) -> K?
      def put: (Symbol key, K value) -> K
    end
    class P
      def current: () -> untyped
      def name: () -> untyped
      def unwritten: () -> untyped
      def written: () -> untyped
      def write: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class K
    end

    class Main
      def self.current = @main ||= allocate

      def initialize
        @name = :main
      end

      def name = @name

      def get(key)
        locals = @locals
        locals ? locals[key] : nil
      end
    end

    class Written
      def self.current = @main ||= allocate

      def get(key)
        locals = @locals
        locals ? locals[key] : nil
      end

      def put(key, value)
        (@locals ||= {})[key] = value
      end
    end

    class P
      def current = Main.current
      def name = Main.current.name
      def unwritten = Main.current.get(:k)
      def written = Written.current.get(:k)
      def write = Written.current.put(:k, K.new)
    end
  RUBY

  def types
    in_tmpdir do
      write("sig/p.rbs", RBS)
      write("app/p.rb", RUBY)
      project = setup_project
      postconditions = Steep::Postconditions::Runner.new(project)
      postconditions.write(postconditions.run)
      project = setup_project
      runner = Steep::Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!
      return body_types(project, current_dir + "app/p.rb")
    end
  end

  def test_a_class_memo_built_by_allocate_holds_an_object_with_no_ivar_set
    found = types

    assert_equal "::Main{@locals: nil, @name: nil}", found.fetch("current")
    assert_equal "nil", found.fetch("name")
    assert_equal "nil", found.fetch("unwritten")
  end

  def test_an_ivar_of_the_allocated_object_a_called_method_writes_is_not_unset
    assert_equal "(::K | nil)", types.fetch("written")
  end
end

require_relative "test_helper"
require_relative "specializations_project_helper"

class WriterReachedByReceiverTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class K
    end
    class Locals
      @name: Symbol
      @locals: Hash[Symbol, K]
      def initialize: () -> void
      def []: (Symbol key) -> K?
      def []=: (Symbol key, K value) -> K
    end
    class Written
      @name: Symbol
      @locals: Hash[Symbol, K]
      def initialize: () -> void
      def []: (Symbol key) -> K?
      def []=: (Symbol key, K value) -> K
    end
    class OrWritten
      @name: Symbol
      @locals: Hash[Symbol, K]
      def initialize: () -> void
      def []: (Symbol key) -> K?
      def []=: (Symbol key, K value) -> K
    end
    class P
      def or_written: () -> untyped
      def write_by_or: () -> untyped
      def unwritten: () -> untyped
      def written: () -> untyped
      def write: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class K
    end

    class Locals
      def initialize
        @name = :main
        @locals = {}
      end

      def [](key) = @locals[key]

      def []=(key, value)
        @locals[key] = value
      end
    end

    class Written
      def initialize
        @name = :main
        @locals = {}
      end

      def [](key) = @locals[key]

      def []=(key, value)
        @locals[key] = value
      end
    end

    class OrWritten
      def initialize
        @name = :main
        @locals = {}
      end

      def [](key) = @locals[key]

      def []=(key, value)
        @locals[key] = value
      end
    end

    class P
      def or_written = OrWritten.new[:k]

      def write_by_or
        written = OrWritten.new
        written[:k] ||= K.new
      end

      def unwritten = Locals.new[:k]
      def written = Written.new[:k]

      def write
        written = Written.new
        written[:k] = K.new
      end
    end

    P.new.write
    P.new.write_by_or
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

  def test_a_writer_whose_every_call_is_on_another_class_writes_nothing_on_the_object
    assert_equal "nil", types.fetch("unwritten")
  end

  def test_a_writer_a_call_may_run_on_the_object_still_writes_it
    found = types

    assert_equal "(::K | nil)", found.fetch("written")
    assert_equal "(::K | nil)", found.fetch("or_written")
  end
end

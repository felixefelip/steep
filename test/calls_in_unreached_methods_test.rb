require_relative "test_helper"
require_relative "specializations_project_helper"

class CallsInUnreachedMethodsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class K
    end
    class UncalledLocals
      @locals: Hash[Symbol, K]?
      def get_uncalled: (Symbol key) -> K?
      def put_uncalled: (Symbol key, K value) -> K
    end
    class CalledLocals
      @locals: Hash[Symbol, K]?
      def get_called: (Symbol key) -> K?
      def put_called: (Symbol key, K value) -> K
    end
    class ThroughLocals
      @locals: Hash[Symbol, K]?
      def get_through: (Symbol key) -> K?
      def put_through: (Symbol key, K value) -> K
    end
    module Uncalled
      @@locals: UncalledLocals?
      def self.locals: () -> UncalledLocals
      def self.clear: () -> K
    end
    module Called
      @@locals: CalledLocals?
      def self.locals: () -> CalledLocals
      def self.reset: () -> K
    end
    module Through
      @@locals: ThroughLocals?
      def self.locals: () -> ThroughLocals
      def self.outer: () -> K
      def self.inner: () -> K
    end
    class P
      def uncalled: () -> untyped
      def called: () -> untyped
      def through: () -> untyped
      def calls: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class K
    end

    class UncalledLocals
      def get_uncalled(key)
        locals = @locals
        locals ? locals[key] : nil
      end

      def put_uncalled(key, value)
        (@locals ||= {})[key] = value
      end
    end

    class CalledLocals
      def get_called(key)
        locals = @locals
        locals ? locals[key] : nil
      end

      def put_called(key, value)
        (@locals ||= {})[key] = value
      end
    end

    class ThroughLocals
      def get_through(key)
        locals = @locals
        locals ? locals[key] : nil
      end

      def put_through(key, value)
        (@locals ||= {})[key] = value
      end
    end

    module Uncalled
      def self.locals = @@locals ||= UncalledLocals.allocate
      def self.clear = locals.put_uncalled(:k, K.new)
    end

    module Called
      def self.locals = @@locals ||= CalledLocals.allocate
      def self.reset = locals.put_called(:k, K.new)
    end

    module Through
      def self.locals = @@locals ||= ThroughLocals.allocate
      def self.outer = inner
      def self.inner = locals.put_through(:k, K.new)
    end

    class P
      def uncalled = Uncalled.locals.get_uncalled(:k)
      def called = Called.locals.get_called(:k)
      def through = Through.locals.get_through(:k)

      def calls
        Called.reset
        Through.outer
      end
    end

    P.new.calls
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

  def test_a_call_made_only_inside_a_method_no_code_runs_writes_nothing
    assert_equal "nil", types.fetch("uncalled")
  end

  def test_a_call_inside_a_method_a_running_call_reaches_still_writes
    found = types

    assert_equal "(::K | nil)", found.fetch("called")
    assert_equal "(::K | nil)", found.fetch("through")
  end
end

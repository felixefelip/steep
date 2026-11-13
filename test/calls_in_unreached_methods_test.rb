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
    class CycleLocals
      @locals: Hash[Symbol, K]?
      def get_cycle: (Symbol key) -> K?
      def put_cycle: (Symbol key, K value) -> K
    end
    class EnteredLocals
      @locals: Hash[Symbol, K]?
      def get_entered: (Symbol key) -> K?
      def put_entered: (Symbol key, K value) -> K
    end
    module Cycle
      @@locals: CycleLocals?
      def self.locals: () -> CycleLocals
      def self.wipe: (?bool all) -> K
    end
    module Entered
      @@locals: EnteredLocals?
      def self.locals: () -> EnteredLocals
      def self.ping: (Integer n) -> K
      def self.pong: (Integer n) -> K
    end
    class HereLocals
      @locals: Hash[Symbol, K]?
      def get_here: (Symbol key) -> K?
      def put_here: (Symbol key, K value) -> K
    end
    module Here
      @@locals: HereLocals?
      def self.locals: () -> HereLocals
    end
    class P
      def here: () -> untyped
      def uncalled: () -> untyped
      def called: () -> untyped
      def through: () -> untyped
      def cycle: () -> untyped
      def entered: () -> untyped
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

    class CycleLocals
      def get_cycle(key)
        locals = @locals
        locals ? locals[key] : nil
      end

      def put_cycle(key, value)
        (@locals ||= {})[key] = value
      end
    end

    class EnteredLocals
      def get_entered(key)
        locals = @locals
        locals ? locals[key] : nil
      end

      def put_entered(key, value)
        (@locals ||= {})[key] = value
      end
    end

    class HereLocals
      def get_here(key)
        locals = @locals
        locals ? locals[key] : nil
      end

      def put_here(key, value)
        (@locals ||= {})[key] = value
      end
    end

    module Here
      def self.locals = @@locals ||= HereLocals.allocate
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

    module Cycle
      def self.locals = @@locals ||= CycleLocals.allocate
      def self.wipe(all = true) = all ? wipe(false) : locals.put_cycle(:k, K.new)
    end

    module Entered
      def self.locals = @@locals ||= EnteredLocals.allocate
      def self.ping(n) = n > 0 ? pong(n - 1) : locals.put_entered(:k, K.new)
      def self.pong(n) = ping(n)
    end

    class P
      def here
        Here.locals.put_here(:k, K.new)
        Here.locals.get_here(:k)
      end

      def uncalled = Uncalled.locals.get_uncalled(:k)
      def called = Called.locals.get_called(:k)
      def through = Through.locals.get_through(:k)
      def cycle = Cycle.locals.get_cycle(:k)
      def entered = Entered.locals.get_entered(:k)

      def calls
        Called.reset
        Through.outer
        Entered.ping(1)
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

  def test_a_call_made_only_inside_methods_that_call_each_other_writes_nothing
    assert_equal "nil", types.fetch("cycle")
  end

  def test_a_call_inside_methods_that_call_each_other_writes_once_a_running_call_enters_them
    assert_equal "(::K | nil)", types.fetch("entered")
  end

  def test_a_call_inside_a_method_a_running_call_reaches_still_writes
    found = types

    assert_equal "(::K | nil)", found.fetch("called")
    assert_equal "(::K | nil)", found.fetch("through")
  end

  def test_a_call_in_the_method_being_checked_runs_though_nothing_calls_it
    assert_equal "(::K | nil)", types.fetch("here")
  end
end

require_relative "test_helper"
require_relative "specializations_project_helper"

class FallbackAheadOfAMemoTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class K
      @v: Symbol
      def initialize: (?Symbol v) -> void
      attr_reader v: Symbol
    end
    class Locals
      self.@main: Locals?
      @locals: Hash[Symbol, K]?
      def self.current: () -> Locals
      def get: (Symbol key) -> K?
    end
    class Unset
      @@x: K?
      def self.x: () -> K
    end
    class MaySet
      @@x: K?
      def self.x: () -> K
      def self.other: () -> K?
    end
    class ReadsTheBody
      @@x: K?
      self.@y: K?
      def self.x: () -> K
    end
    class P
      def unset: () -> untyped
      def may_set: () -> untyped
      def reads_the_body: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class K
      def initialize(v = :a)
        @v = v
      end
      attr_reader :v
    end

    class Locals
      def self.current = @main ||= allocate

      def get(key)
        locals = @locals
        locals ? locals[key] : nil
      end
    end

    class Unset
      @@x = nil

      def self.x
        @@x ||= K.new
        Locals.current.get(:k) || @@x
      end
    end

    class MaySet
      def self.x
        @@x ||= K.new
        MaySet.other || @@x
      end

      def self.other = [K.new(:b), nil].sample
    end

    class ReadsTheBody
      def self.x
        @@x ||= K.new
        @y || @@x
      end
    end

    class P
      def unset = Unset.x.v
      def may_set = MaySet.x.v
      def reads_the_body = ReadsTheBody.x.v
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

  def test_a_value_read_ahead_of_a_memo_that_is_nil_hands_back_the_memo
    assert_equal ":a", types.fetch("unset")
  end

  def test_a_value_read_ahead_of_a_memo_that_may_be_an_object_is_not_the_memo
    found = types

    assert_equal "::Symbol", found.fetch("may_set")
    assert_equal "::Symbol", found.fetch("reads_the_body")
  end
end

require_relative "test_helper"
require_relative "specializations_project_helper"

class MemoSetInAStatementTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class K
      @v: Symbol
      def initialize: (?Symbol v) -> void
      attr_reader v: Symbol
    end
    class InIvar
      self.@x: K?
      def self.x: () -> K
    end
    class InCvar
      @@x: K?
      def self.x: () -> K
    end
    class ReadThroughABranch
      @@x: K?
      def self.x: () -> K
    end
    class SetAgain
      self.@x: K?
      def self.x: () -> K
    end
    class HandsBackAnother
      self.@x: K?
      def self.x: () -> K
    end
    class P
      def in_ivar: () -> untyped
      def in_cvar: () -> untyped
      def read_through_a_branch: () -> untyped
      def set_again: () -> untyped
      def hands_back_another: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class K
      def initialize(v = :a)
        @v = v
      end
      attr_reader :v
    end

    class InIvar
      def self.x
        @x ||= K.new
        @x
      end
    end

    class InCvar
      @@x = nil

      def self.x
        @@x ||= K.new
        @@x
      end
    end

    class ReadThroughABranch
      def self.x
        @@x ||= K.new
        @@x.nil? ? @@x : @@x
      end
    end

    class SetAgain
      def self.x
        @x ||= K.new
        @x = K.new(:b)
        @x
      end
    end

    class HandsBackAnother
      def self.x
        @x ||= K.new
        K.new(:b)
      end
    end

    class P
      def in_ivar = InIvar.x.v
      def in_cvar = InCvar.x.v
      def read_through_a_branch = ReadThroughABranch.x.v
      def set_again = SetAgain.x.v
      def hands_back_another = HandsBackAnother.x.v
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

  def test_a_memo_set_in_a_statement_and_handed_back_after_it_answers_the_object_it_builds
    found = types

    assert_equal ":a", found.fetch("in_ivar")
    assert_equal ":a", found.fetch("in_cvar")
    assert_equal ":a", found.fetch("read_through_a_branch")
  end

  def test_a_body_that_hands_back_something_else_than_its_memo_answers_what_it_hands_back
    found = types

    assert_equal ":b", found.fetch("set_again")
    assert_equal ":b", found.fetch("hands_back_another")
  end
end

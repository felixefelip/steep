require_relative "test_helper"
require_relative "specializations_project_helper"

class ClassVariableMemoTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class K
      @v: Symbol
      def initialize: (?Symbol v) -> void
      attr_reader v: Symbol
    end
    class Memo
      @@x: K?
      def self.x: () -> K
    end
    module InModule
      @@x: K?
      def self.x: () -> K
    end
    class Unrelated
      @@x: K?
      def self.x: () -> K
    end
    class UncalledWriter
      @@x: K?
      def self.x: () -> K
      def self.clear: () -> K
    end
    class CalledWriter
      @@x: K?
      def self.x: () -> K
      def self.reset: () -> K
    end
    class SetByBody
      @@x: K?
      def self.x: () -> K
    end
    class Base
      @@x: K?
      def self.x: () -> K
    end
    class Sub < Base
      def write: () -> K
    end
    class P
      def memo: () -> untyped
      def in_module: () -> untyped
      def uncalled_writer: () -> untyped
      def called_writer: () -> untyped
      def set_by_body: () -> untyped
      def written_by_subclass: () -> untyped
      def reset: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class K
      def initialize(v = :a)
        @v = v
      end
      attr_reader :v
    end

    class Memo
      @@x = nil
      def self.x = @@x ||= K.new
    end

    module InModule
      @@x = nil

      class << self
        def x = @@x ||= K.new
      end
    end

    class Unrelated
      def self.x = @@x ||= K.new(:b)
    end

    class UncalledWriter
      def self.x = @@x ||= K.new
      def self.clear = @@x = K.new(:b)
    end

    class CalledWriter
      def self.x = @@x ||= K.new
      def self.reset = @@x = K.new(:b)
    end

    class SetByBody
      @@x = K.new(:b)
      def self.x = @@x ||= K.new
    end

    class Base
      def self.x = @@x ||= K.new
    end

    class Sub < Base
      def write = @@x = K.new(:b)
    end

    class P
      def memo = Memo.x.v
      def in_module = InModule.x.v
      def uncalled_writer = UncalledWriter.x.v
      def called_writer = CalledWriter.x.v
      def set_by_body = SetByBody.x.v
      def written_by_subclass = Base.x.v
      def reset = [CalledWriter.reset, Sub.new.write]
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

  def test_a_class_variable_memo_nothing_else_sets_answers_the_object_it_builds
    found = types

    assert_equal ":a", found.fetch("memo")
    assert_equal ":a", found.fetch("in_module")
    assert_equal ":a", found.fetch("uncalled_writer")
  end

  def test_a_class_variable_memo_another_code_may_set_answers_the_class
    found = types

    assert_equal "::Symbol", found.fetch("called_writer")
    assert_equal "::Symbol", found.fetch("set_by_body")
    assert_equal "::Symbol", found.fetch("written_by_subclass")
  end
end

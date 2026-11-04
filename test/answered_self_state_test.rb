require_relative "test_helper"
require_relative "specializations_project_helper"

class AnsweredSelfStateTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class D
      @tag: Symbol
      def initialize: (Symbol tag) -> void
      attr_reader tag: Symbol
      def itself_: () -> D
      def selfs: () -> Array[D]
    end
    class E
      @tag: Symbol
      def initialize: (Symbol tag) -> void
      attr_reader tag: Symbol
      def renamed: () -> E
    end
    class P
      def itself_: (:fr locale) -> untyped
      def selfs: (:fr locale) -> untyped
      def mapped: (:fr locale) -> untyped
      def renamed: (:fr locale) -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class D
      def initialize(tag)
        @tag = tag
      end

      attr_reader :tag

      def itself_ = self
      def selfs = [self]
    end

    class E
      def initialize(tag)
        @tag = tag
      end

      attr_reader :tag

      def renamed
        @tag = :en
        self
      end
    end

    class P
      def itself_(locale) = D.new(locale).itself_.tag
      def selfs(locale) = D.new(locale).selfs
      def mapped(locale) = D.new(locale).selfs.map { |d| d.tag }
      def renamed(locale) = E.new(locale).renamed.tag
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

  def test_a_method_answering_self_or_an_array_of_it_keeps_the_receivers_state
    found = types

    assert_equal ":fr", found.fetch("itself_")
    assert_equal "[::D{@tag: :fr}]", found.fetch("selfs")
    assert_equal "[:fr]", found.fetch("mapped")
  end

  def test_declines_the_state_the_receiver_held_before_a_body_that_changes_it
    refute_equal ":fr", types.fetch("renamed")
  end
end

require_relative "test_helper"
require_relative "specializations_project_helper"

class HeldTupleElementsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class D
      @tag: Symbol
      def initialize: (Symbol tag) -> void
      attr_reader tag: Symbol
      def selves: () -> Array[D]
      def joined: () -> Array[D]
      def count: () -> Integer
      def listed: () -> bool
      def unique: () -> Array[D]
      def wrapped: () -> Array[D]
    end
    class P
      def selves: (:fr locale) -> untyped
      def joined: (:fr locale) -> untyped
      def tags: (:fr locale) -> untyped
      def count: (:fr locale) -> untyped
      def listed: (:fr locale) -> untyped
      def unique: (:fr locale) -> untyped
      def wrapped: (:fr locale) -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class D
      def initialize(tag)
        @tag = tag
      end

      attr_reader :tag

      def selves = [self]
      def joined = [self].concat([])
      def count = [self, tag].concat([]).length
      def listed = [self].include?(D.new(:fr))
      def unique = [self].uniq
      def wrapped = [D.new(tag)]
    end

    class P
      def selves(locale) = D.new(locale).selves
      def joined(locale) = D.new(locale).joined
      def tags(locale) = D.new(locale).joined.map { |d| d.tag }
      def count(locale) = D.new(locale).count
      def listed(locale) = D.new(locale).listed
      def unique(locale) = D.new(locale).unique
      def wrapped(locale) = D.new(locale).wrapped
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

  def test_an_array_holding_the_receiver_folds_through_operations_that_move_elements
    found = types

    assert_equal "[::D{@tag: :fr}]", found.fetch("selves")
    assert_equal "[::D{@tag: :fr}]", found.fetch("joined")
    assert_equal "[:fr]", found.fetch("tags")
    assert_equal "2", found.fetch("count")
  end

  def test_an_array_written_around_an_object_with_state_is_a_tuple_of_it
    assert_equal "[::D{@tag: :fr}]", types.fetch("wrapped")
  end

  def test_declines_operations_that_compare_or_hash_elements
    found = types

    assert_equal "bool", found.fetch("listed")
    refute_match(/\A\[/, found.fetch("unique"))
  end
end

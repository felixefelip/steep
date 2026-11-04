require_relative "test_helper"
require_relative "specializations_project_helper"

# `I18n::Locale::Tag::Parents` on a locale of two segments: `fr-CA`'s parent is
# `fr`, built by `self.class.tag(*segs[0..(segs.length - 2)].join('-'))`.
class TwoSegmentParentTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    module Parents
      @parent: Simple?
      @parents: Array[Simple]
      @self_and_parents: Array[Simple]
      def self_and_parents: () -> Array[Simple]
      def parent: () -> Simple?
      def parents: () -> Array[Simple]
    end
    class Simple
      include Parents
      @tag: Symbol
      @subtags: Array[String]
      def self.tag: (Symbol | String tag) -> Simple
      def initialize: (*(Symbol | String) tag) -> void
      attr_reader tag: Symbol
      def subtags: () -> Array[String]
      def to_a: () -> Array[String]
      def sliced: () -> String
      def passed: () -> Simple
      def splatted: () -> Simple
    end
    class P
      def sliced: (:"fr-CA" locale) -> untyped
      def passed: (:"fr-CA" locale) -> untyped
      def splatted: (:"fr-CA" locale) -> untyped
      def parent: (:"fr-CA" locale) -> untyped
      def parents: (:"fr-CA" locale) -> untyped
      def tags: (:"fr-CA" locale) -> untyped
      def one_tag: (:fr locale) -> untyped
    end
  RBS

  RUBY = <<~RUBY
    module Parents
      # @type instance: Simple & Parents
      def parent
        @parent ||=
          begin
            segs = to_a
            segs.compact!
            segs.length > 1 ? self.class.tag(*segs[0..(segs.length - 2)].join('-')) : nil
          end
      end

      def parents
        @parents ||= parent ? [parent].concat(parent.parents) : []
      end

      def self_and_parents
        @self_and_parents ||= [self].concat parents
      end
    end

    class Simple
      def self.tag(tag) = new(tag)

      include Parents

      attr_reader :tag

      def initialize(*tag)
        @tag = tag.join('-').to_sym
      end

      def subtags
        @subtags = tag.to_s.split('-').map!(&:to_s)
      end

      def to_a = subtags

      def sliced
        segs = to_a
        segs[0..(segs.length - 2)].join('-')
      end

      def passed
        segs = to_a
        self.class.tag(segs.join('-'))
      end

      def splatted = self.class.tag(*"fr")
    end

    class P
      def sliced(locale) = Simple.new(locale).sliced
      def passed(locale) = Simple.new(locale).passed
      def splatted(locale) = Simple.new(locale).splatted
      def parent(locale) = Simple.new(locale).parent
      def parents(locale) = Simple.new(locale).parents
      def tags(locale) = Simple.new(locale).self_and_parents.map { |t| t.tag }
      def one_tag(locale) = Simple.new(locale).self_and_parents.map { |t| t.tag }
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

  def test_a_slice_of_a_local_tuple_by_a_range_it_computes_folds
    assert_equal "\"fr\"", types.fetch("sliced")
  end

  def test_a_call_through_a_splat_of_a_value_with_no_to_a_specializes
    assert_equal "::Simple{@tag: :fr}", types.fetch("splatted")
  end

  def test_a_local_read_past_self_class_keeps_what_a_method_answered
    assert_equal "::Simple{@tag: :\"fr-CA\"}", types.fetch("passed")
  end

  def test_a_two_segment_locale_answers_its_parent_and_the_chain_of_them
    found = types

    assert_equal "::Simple{@tag: :fr}", found.fetch("parent")
    assert_equal "[::Simple{@tag: :fr}]", found.fetch("parents")
  end

  def test_a_locale_and_its_parents_answer_their_tags
    found = types

    assert_equal "[:\"fr-CA\", :fr]", found.fetch("tags")
    assert_equal "[:fr]", found.fetch("one_tag")
  end
end

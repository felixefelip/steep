require_relative "test_helper"
require_relative "specializations_project_helper"
require_relative "forwarded_map_fixture"

class ClassStateInForwardedHashTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper
  include ForwardedMapFixture

  RUBY = <<~RUBY
    class MMap < MLocked
    end

    module Inf
      class Rules
        @__instance__ = MMap.new
        attr_reader :singulars

        def self.instance(locale = :en) = (@__instance__[locale] ||= new)

        def initialize
          @singulars = []
        end

        def singular(rule, replacement)
          @singulars.prepend([rule, replacement])
        end
      end

      def self.inflections(locale = :en)
        if block_given?
          yield Rules.instance(locale)
        else
          Rules.instance(locale)
        end
      end
    end

    module Inf
      inflections(:en) do |inflect|
        inflect.singular(/(octop|vir)(us|i)$/i, '\\1us')
        inflect.singular(/s$/i, "")
      end
    end
    %{writer}
    class Post
      def self.singularize(word)
        result = word.dup
        Inf.inflections(:en).singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end

      def self.m(name) = class_eval("def \#{singularize(name.to_s)}_ids; []; end")
      m :posts
    end
  RUBY

  APP_RBS = <<~RBS
    module Inf
      class Rules
        self.@__instance__: MMap[Symbol, Rules]
        attr_reader singulars: Array[untyped]
        def self.instance: (?Symbol locale) -> Rules
        def initialize: () -> void
        def singular: (untyped rule, untyped replacement) -> Array[untyped]
      end
      def self.inflections: (?Symbol locale) ?{ (untyped) -> untyped } -> untyped
    end
    class Other
      def self.add: () -> untyped
    end
    class Post
      def self.singularize: (String word) -> String
      def self.m: (Symbol name) -> untyped
    end
  RBS

  def chunks(writer: "")
    in_tmpdir do
      write("sig/map.rbs", RBS)
      write("sig/app.rbs", APP_RBS)
      write("app/app.rb", MUTEX + BACKEND + format(RUBY, writer: writer))
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.evals.values.flatten.map { |chunk| chunk&.source }
    end
  end

  def test_a_block_writes_the_object_another_class_keeps_in_a_map_it_set_its_ivar_to
    assert_equal ["def post_ids; []; end"], chunks
  end

  def test_declines_an_object_kept_in_a_map_another_class_may_write
    writer = "class Other\n  def self.add = Inf::Rules.instance(:en).singular(/s$/i, \"z\")\nend\nOther.add\n"

    assert_equal [nil], chunks(writer: writer)
  end
end

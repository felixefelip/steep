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

        def describe = @singulars.size
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
    class Base
      def self.define_readers(model, name) = (model.describe if model.respond_to?(:describe))
    end

    class Coll < Base
      def self.define_readers(model, name)
        super
        model.class_eval("def \#{Post.singularize(name.to_s)}_ids; []; end")
      end
    end

    class Post
      def self.singularize(word)
        result = word.dup
        Inf.inflections(:en).singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end

      %{macro}
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
        def describe: () -> Integer
      end
      def self.inflections: (?Symbol locale) ?{ (untyped) -> untyped } -> untyped
    end
    class Other
      def self.add: () -> untyped
    end
    class Base
      def self.define_readers: (untyped model, Symbol name) -> untyped
    end
    class Coll < Base
      def self.define_readers: (untyped model, Symbol name) -> untyped
    end
    class Post
      def self.singularize: (String word) -> String
      def self.m: (Symbol name) -> untyped
    end
  RBS

  MACRO = 'def self.m(name) = class_eval("def #{singularize(name.to_s)}_ids; []; end")'

  def chunks(writer: "", macro: MACRO, ruby: RUBY, app_rbs: APP_RBS)
    in_tmpdir do
      write("sig/map.rbs", RBS)
      write("sig/app.rbs", app_rbs)
      write("app/app.rb", MUTEX + BACKEND + format(ruby, writer: writer, macro: macro))
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

  def test_a_super_into_a_body_that_reaches_no_method_of_the_class_keeps_its_state
    assert_equal ["def post_ids; []; end"], chunks(macro: "def self.m(name) = Coll.define_readers(self, name)")
  end

  def test_declines_an_object_kept_in_a_map_another_class_may_write
    writer = "class Other\n  def self.add = Inf::Rules.instance(:en).singular(/s$/i, \"z\")\nend\nOther.add\n"

    assert_equal [nil], chunks(writer: writer)
  end

  READER = "class Other\n  def self.add = Inf.inflections(:en)\nend\n"

  def test_a_send_by_a_literal_name_calls_the_method_where_it_is_made
    {
      "send" => "Other.send(:add)",
      "public_send" => "Other.public_send(:add)",
      "__send__" => "Other.__send__(:add)",
      "a string name" => 'Other.send("add")',
      "in a method" => "def self.z = Other.send(:add)"
    }.each do |label, call|
      assert_equal ["def post_ids; []; end"], chunks(writer: READER, ruby: "#{RUBY}class Z\n  #{call}\nend\n"), label
    end
  end

  def test_a_call_at_the_top_level_of_a_file_runs_as_it_loads
    ["Other.add", "Other.send(:add)"].each do |call|
      assert_equal ["def post_ids; []; end"], chunks(writer: READER, ruby: "#{RUBY}#{call}\n"), call
    end
  end

  def test_declines_a_call_at_the_top_level_in_a_block_a_proc_keeps
    assert_equal [nil], chunks(writer: READER, ruby: "#{RUBY}KEPT = proc { Other.add }\n")
  end

  def test_declines_a_method_named_as_a_value
    assert_equal [nil], chunks(writer: READER, ruby: "#{RUBY}class Z\n  Other.method(:add)\nend\n")
  end

  def test_a_rule_written_through_a_helper_folds_once_the_helper_does
    ruby = RUBY
      .sub("      @singulars.prepend([rule, replacement])\n", "      @singulars.prepend([rule, tail(replacement)])\n")
      .sub("    def describe = @singulars.size\n", "    def describe = @singulars.size\n\n    private def tail(replacement) = \"\#{replacement}\"\n")
    app_rbs = APP_RBS.sub("    def describe: () -> Integer\n", "    def describe: () -> Integer\n    private def tail: (untyped replacement) -> String\n")

    assert_equal ["def post_ids; []; end"], chunks(ruby: ruby, app_rbs: app_rbs)
  end
end

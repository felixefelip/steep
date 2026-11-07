require_relative "test_helper"
require_relative "specializations_project_helper"

class KeyedMemoAnswersItsValueTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class Locales < Hash[Symbol, Array[untyped]]
      @defaults: Array[untyped]
      @map: Hash[Symbol, untyped]
      def initialize: (*untyped mappings) -> void
      def add: (untyped mappings) -> untyped
      def defaults=: (Array[untyped] defaults) -> Array[untyped]
      attr_reader defaults: Array[untyped]
      def []: (Symbol locale) -> Array[untyped]
      def compute: (Symbol locale) -> Array[untyped]
    end
    module Holder
      @@locales: Locales?
      def self.locales: () -> Locales
    end
    class Other
      @map: Integer
      def initialize: () -> void
      def add: () -> Integer
    end
    class P
      def en: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class Locales < Hash
      def initialize(*mappings)
        @map = {}
        add(mappings.pop) if mappings.last.is_a?(Hash)
        self.defaults = []
      end

      def add(mappings)
        @map[:pt] = mappings
        @map.map { |key, value| [key, value] }
      end

      def defaults=(defaults)
        @defaults = defaults.flat_map { |default| [default] }
      end
      attr_reader :defaults

      def [](locale)
        super || store(locale, compute(locale))
      end

      def compute(locale)
        result = [locale]
        result.push(@map[locale]) if @map[locale]
        result.push(*defaults)
        result
      end
    end

    module Holder
      def self.locales = @@locales ||= Locales.new
    end

    class Other
      def initialize
        @map = Integer("1")
      end

      def add = @map
    end
    Other.new.add

    class P
      def en = Holder.locales[:en]
    end
    P.new.en
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

  def test_a_keyed_memo_reads_an_array_the_constructor_left_and_answers_its_literal_value
    assert_equal "[:en]", types.fetch("en")
  end

  def test_any_type_refines_untyped_and_nothing_else_it_does_not_descend_from
    tuple = Steep::AST::Types::Tuple.new(types: [Steep::AST::Types::Literal.new(value: :en)])
    array_of = ->(element) { Steep::AST::Builtin::Array.instance_type(element) }

    assert Steep::Specializations.refines?(tuple, array_of[Steep::AST::Builtin.any_type])
    refute Steep::Specializations.refines?(tuple, array_of[Steep::AST::Builtin::Integer.instance_type])
  end
end

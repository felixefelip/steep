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
      def map: (untyped mappings) -> untyped
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
      def map: () -> Integer
    end
    class P
      def en: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class Locales < Hash
      def initialize(*mappings)
        @map = {}
        map(mappings.pop) if mappings.last.is_a?(Hash)
        self.defaults = []
      end

      def map(mappings)
        @map[:pt] = mappings
        @map.map(&mappings)
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

      def map = @map
    end
    Other.new.map

    class P
      def en = Holder.locales[:en]
    end
    P.new.en
  RUBY

  LOCALS = <<~RUBY
    class Locals
      def self.current = @main ||= allocate

      def [](key)
        locals = @locals
        return nil unless locals

        locals[key]
      end

      def []=(key, value)
        (@locals ||= {})[key] = value
      end
    end

    module Holder
      module Tag
        def self.tag(locale) = [locale]
      end
    end
  RUBY

  LOCALS_RBS = <<~RBS
    class Locals
      self.@main: Locals?
      @locals: Hash[Symbol, untyped]?
      def self.current: () -> Locals
      def []: (Symbol key) -> untyped
      def []=: (Symbol key, untyped value) -> untyped
    end
    module Holder
      module Tag
        def self.tag: (Symbol locale) -> Array[Symbol]
      end
    end
  RBS

  def types(ruby = RUBY, rbs = RBS)
    in_tmpdir do
      write("sig/p.rbs", rbs)
      write("app/p.rb", ruby)
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

  def test_a_keyed_memo_behind_a_local_of_the_current_thread_answers_its_literal_value
    holder = "  @@locales = nil\n\n  def self.locales\n    @@locales ||= Locales.new\n    Locals.current[:locales] || @@locales\n  end\n"
    ruby = LOCALS + RUBY.sub("  def self.locales = @@locales ||= Locales.new\n", holder).sub("result = [locale]", "result = Holder::Tag.tag(locale)")

    assert_equal "[:en]", types(ruby, RBS + LOCALS_RBS).fetch("en")
  end

  def test_any_type_refines_untyped_and_nothing_else_it_does_not_descend_from
    tuple = Steep::AST::Types::Tuple.new(types: [Steep::AST::Types::Literal.new(value: :en)])
    array_of = ->(element) { Steep::AST::Builtin::Array.instance_type(element) }

    assert Steep::Specializations.refines?(tuple, array_of[Steep::AST::Builtin.any_type])
    refute Steep::Specializations.refines?(tuple, array_of[Steep::AST::Builtin::Integer.instance_type])
  end
end

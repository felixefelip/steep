require_relative "test_helper"
require_relative "specializations_project_helper"

class DefinedMethodsTest < Minitest::Test
  include TestHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper
  include ShellHelper
  include SpecializationsProjectHelper

  Diagnostic = Steep::Diagnostic

  def dirs = (@dirs ||= [])

  COUNTER = <<~RBS
    class Module
      def define_method: (Symbol name) { (?) -> untyped } -> Symbol
    end

    class Counter
      @count: Integer
      def size: () -> Integer
      def named: (String name) -> String
    end
  RBS

  FACTORY = <<~RBS
    class Module
      def define_method: (Symbol name) { (?) -> untyped } -> Symbol
    end

    class Object
      def singleton_class: () -> Class
    end

    class Factory
      def self.build: () -> Factory
    end
  RBS

  def test_a_define_method_block_is_checked_as_the_method
    with_checker(COUNTER) do |checker|
      source = parse_ruby(<<~'RUBY')
        class Counter
          define_method(:size) { @count }
          define_method(:named) { |name| name }
        end
      RUBY

      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)

        assert_no_error typing
        assert_equal parse_type("::Integer"), typing.type_of(node: dig(source.node, 2, 0, 2))
        assert_equal parse_type("::String"), typing.type_of(node: dig(source.node, 2, 1, 2))
      end
    end
  end

  def test_a_define_method_block_returning_another_type_is_a_body_mismatch
    with_checker(COUNTER) do |checker|
      source = parse_ruby(<<~'RUBY')
        class Counter
          define_method(:size) { "many" }
          def named(name) = name
        end
      RUBY

      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)

        assert_typing_error(typing, size: 1) do |errors|
          assert_any!(errors) { assert_instance_of Diagnostic::Ruby::MethodBodyTypeMismatch, _1 }
        end
      end
    end
  end

  def test_a_block_reading_a_local_of_the_class_body_stays_a_block
    with_checker(COUNTER) do |checker|
      source = parse_ruby(<<~'RUBY')
        class Counter
          many = "many"
          define_method(:size) { many }
          def named(name) = name
        end
      RUBY

      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)

        assert_equal [Diagnostic::Ruby::MethodDefinitionMissing], typing.errors.map(&:class)
      end
    end
  end

  def test_a_define_method_block_on_the_singleton_class_is_checked_as_a_class_method
    with_checker(FACTORY) do |checker|
      source = parse_ruby(<<~'RUBY')
        class Factory
          singleton_class.define_method(:build) { new }
        end
      RUBY

      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)

        assert_no_error typing
        assert_equal parse_type("::Factory"), typing.type_of(node: dig(source.node, 2, 2))
      end
    end
  end

  def test_a_define_method_on_the_singleton_class_inside_class_self_stays_a_block
    with_checker(FACTORY) do |checker|
      source = parse_ruby(<<~'RUBY')
        class Factory
          class << self
            singleton_class.define_method(:build) { "many" }
          end
          def self.build = new
        end
      RUBY

      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)

        assert_no_error typing
      end
    end
  end

  def test_a_call_to_a_defined_method_keeps_the_memo_it_does_not_build
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          self.@generated_methods: Module?
          def self.generated_methods: () -> Module
          def self.define_reader: (Symbol name) -> untyped
          def self.pluralize: () -> bool
        end
        class Widget < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          class << self
            define_method(:pluralize) { true }
          end

          def self.generated_methods
            @generated_methods ||= begin
              mod = const_set(:GeneratedMethods, Module.new)
              include mod
              mod
            end
          end

          def self.define_reader(name)
            pluralize
            generated_methods.class_eval "def \#{name}; 1; end"
          end
        end

        class Widget < Base
          define_reader :size
        end
      RUBY

      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      chunks = runner.evals.fetch("app/base.rb:21:2").map { |chunk| chunk&.source }

      assert_equal ["module GeneratedMethods\nend", nil], chunks
    end
  end

  def test_a_call_to_a_method_defined_on_the_singleton_class_keeps_the_memo
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          self.@generated_methods: Module?
          def self.generated_methods: () -> Module
          def self.define_reader: (Symbol name) -> untyped
          def self.pluralize: () -> bool
        end
        class Widget < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          singleton_class.define_method(:pluralize) { true }

          def self.generated_methods
            @generated_methods ||= begin
              mod = const_set(:GeneratedMethods, Module.new)
              include mod
              mod
            end
          end

          def self.define_reader(name)
            pluralize
            generated_methods.class_eval "def \#{name}; 1; end"
          end
        end

        class Widget < Base
          define_reader :size
        end
      RUBY

      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      chunks = runner.evals.fetch("app/base.rb:19:2").map { |chunk| chunk&.source }

      assert_equal ["module GeneratedMethods\nend", nil], chunks
    end
  end

  def test_a_defined_method_is_specialized_by_its_call_sites
    in_tmpdir do
      write("sig/tagger.rbs", <<~RBS)
        class Tagger
          def tag: (Symbol name) -> String
        end
        class Caller
          def label: () -> String
        end
      RBS
      write("app/tagger.rb", <<~'RUBY')
        class Tagger
          define_method(:tag) { |name| "#{name}!" }
        end

        class Caller
          def label = Tagger.new.tag(:a)
        end
      RUBY
      project = setup_project
      runner = Steep::Specializations::Runner.new(project)
      methods = runner.run

      assert_equal({ "(:a)" => '"a!"' }, methods.fetch("Tagger#tag"))

      runner.write(methods)
      project.reload_specializations!

      assert_equal '"a!"', body_types(project, current_dir + "app/tagger.rb").fetch("label")
    end
  end
end

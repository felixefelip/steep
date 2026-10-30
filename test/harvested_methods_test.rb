require_relative "test_helper"
require_relative "specializations_project_helper"

class HarvestedMethodsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def store_project(store_rbs:, attr_ruby:, base_ruby:)
    write("sig/base.rbs", <<~RBS)
      class Base
        self.@generated_methods: Module?
        def self.generated_methods: () -> Module
        def self.define_reader: (Symbol name) -> untyped
        def self.pluralize: () -> untyped
        #{store_rbs}
      end
      class Widget < Base
      end
      module Attr
        def self.redefine: (untyped owner, Symbol name, Integer value) -> void
        def self.redefine_method: (untyped owner, Symbol name) { (?) -> untyped } -> void
      end
    RBS
    write("app/attr.rb", attr_ruby)
    write("app/base.rb", <<~RUBY)
      class Base
        #{base_ruby}

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
    setup_project
  end

  FORWARDED = <<~RUBY
    module Attr
      def self.redefine(owner, name, value)
        redefine_method(owner.singleton_class, name) { value }
      end

      def self.redefine_method(owner, name, &block)
        owner.define_method(name, &block)
      end
    end
  RUBY

  def test_a_store_defined_through_forwarded_frames_keeps_the_memo
    in_tmpdir do
      project = store_project(
        store_rbs: "def self.__store: () -> untyped",
        attr_ruby: FORWARDED,
        base_ruby: "def self.pluralize = __store\n  Attr.redefine(self, :__store, 1)"
      )
      runner = Steep::Specializations::Runner.new(project)
      runner.run

      assert_equal ["module GeneratedMethods\nend", nil], runner.evals.fetch("app/base.rb:20:2").map { |chunk| chunk&.source }
    end
  end

  def test_a_defined_block_reads_the_local_it_closes_over_as_its_frame_has_it
    in_tmpdir do
      project = store_project(
        store_rbs: "def self.__store: () -> untyped",
        attr_ruby: FORWARDED,
        base_ruby: "def self.pluralize = __store\n  Attr.redefine(self, :__store, 1)"
      )
      methods = Steep::Specializations::Runner.new(project).run

      assert_equal ["::Integer"], methods.fetch("Base.__store").values.uniq
    end
  end

  def test_a_local_another_block_of_the_frame_assigns_is_read_as_untyped
    in_tmpdir do
      project = store_project(
        store_rbs: "def self.__store: () -> untyped\n  def self.__store=: (untyped) -> untyped",
        attr_ruby: <<~RUBY,
          module Attr
            def self.redefine(owner, name, value)
              redefine_method(owner.singleton_class, name) { value }
              redefine_method(owner.singleton_class, :"\#{name}=") { |new_value| value = new_value }
            end

            def self.redefine_method(owner, name, &block)
              owner.define_method(name, &block)
            end
          end
        RUBY
        base_ruby: "def self.pluralize = __store\n  Attr.redefine(self, :__store, 1)"
      )
      runner = Steep::Specializations::Runner.new(project)
      methods = runner.run

      refute methods.key?("Base.__store")
      assert_equal ["module GeneratedMethods\nend", nil], runner.evals.fetch("app/base.rb:20:2").map { |chunk| chunk&.source }
    end
  end

  def test_one_block_defining_two_methods_closes_over_neither_call_s_value
    in_tmpdir do
      project = store_project(
        store_rbs: "def self.__a: () -> untyped\n  def self.__b: () -> untyped",
        attr_ruby: FORWARDED,
        base_ruby: "def self.pluralize = [__a, __b]\n  Attr.redefine(self, :__a, 1)\n  Attr.redefine(self, :__b, 2)"
      )
      methods = Steep::Specializations::Runner.new(project).run

      assert_equal ["::Integer"], methods.fetch("Base.__a").values.uniq
      assert_equal ["::Integer"], methods.fetch("Base.__b").values.uniq
    end
  end

  def test_a_store_no_signature_names_is_written_for_its_declaration
    in_tmpdir do
      project = store_project(
        store_rbs: "",
        attr_ruby: FORWARDED.sub("{ value }", "{ |given = nil, *rest, key:| value }"),
        base_ruby: "def self.pluralize = 1\n  Attr.redefine(self, :__store, 1)"
      )
      runner = Steep::Specializations::Runner.new(project)
      runner.write(runner.run)

      expected = { "Base.__store" => { "params" => "(?untyped given, *untyped rest, key: untyped)", "returns" => "untyped" } }
      assert_equal expected, runner.defined_methods
      assert_equal({ "version" => 1, "methods" => expected }, YAML.safe_load((current_dir + "sig/generated/.steep_defined_methods.yml").read))
    end
  end

  def test_a_declared_store_is_written_with_what_its_calls_return
    in_tmpdir do
      project = store_project(
        store_rbs: "def self.__store: () -> untyped",
        attr_ruby: FORWARDED,
        base_ruby: "def self.pluralize = __store\n  Attr.redefine(self, :__store, 1)"
      )
      runner = Steep::Specializations::Runner.new(project)
      runner.run

      assert_equal({ "Base.__store" => { "params" => "()", "returns" => "::Integer" } }, runner.defined_methods)
    end
  end
end

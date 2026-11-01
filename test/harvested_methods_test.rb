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
        def self.redefine: (untyped owner, Symbol name, 1 | 2 value) -> void
        def self.redefine_method: (untyped owner, Symbol | String name) { (?) -> untyped } -> void
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

      assert_equal ["(1 | 2)"], methods.fetch("Base.__store").values.uniq
    end
  end

  def test_a_local_another_block_of_the_frame_assigns_is_read_widened
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

      assert_equal ["::Integer"], methods.fetch("Base.__store").values.uniq
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

      assert_equal ["(1 | 2)"], methods.fetch("Base.__a").values.uniq
      assert_equal ["(1 | 2)"], methods.fetch("Base.__b").values.uniq
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

      expected = { "Base.__store" => { "params" => "(?untyped given, *untyped rest, key: untyped)", "returns" => "untyped", "block" => "app/attr.rb:3:4" } }
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

      assert_equal({ "Base.__store" => { "params" => "()", "returns" => "(1 | 2)", "block" => "app/attr.rb:3:4" } }, runner.defined_methods)
    end
  end

  def test_only_what_a_call_site_runs_for_certain_defines_a_method
    in_tmpdir do
      project = store_project(
        store_rbs: "def self.__store: () -> untyped",
        attr_ruby: <<~'RUBY',
          module Attr
            def self.redefine(owner, name, value)
              redefine_method(owner, name) { value } if owner.frozen?
              redefine_method(owner.singleton_class, name) { value }
              redefine_method(owner.singleton_class, "#{name}=") do |new_value|
                Attr.redefine(self, name, new_value)
              end
            end

            def self.redefine_method(owner, name, &block)
              owner.define_method(name, &block)
            end
          end
        RUBY
        base_ruby: "def self.pluralize = __store\n  Attr.redefine(self, :__store, 1)"
      )
      runner = Steep::Specializations::Runner.new(project)
      runner.run

      assert_equal ["Base.__store", "Base.__store="], runner.defined_methods.keys.sort
    end
  end

  def test_a_self_handed_on_from_a_class_method_is_the_class_that_hands_it
    in_tmpdir do
      base_ruby = "def self.pluralize = __store\n  def self.setup = Attr.redefine(self, :__store, 1)\n  setup"

      assert_equal ["Base.__store"], defined_keys(base_ruby: base_ruby, store_rbs: "def self.__store: () -> untyped\n  def self.setup: () -> untyped")
    end
  end

  def test_an_ordinary_check_reads_a_found_block_as_the_method_it_defines
    in_tmpdir do
      project = store_project(
        store_rbs: "def self.__store: () -> untyped\n  def self.__store=: (untyped) -> untyped",
        attr_ruby: <<~'RUBY',
          module Attr
            def self.redefine(owner, name, value)
              redefine_method(owner.singleton_class, name) { value }
              redefine_method(owner.singleton_class, "#{name}=") do |new_value|
                Attr.redefine(self, name, new_value)
              end
            end

            def self.redefine_method(owner, name, &block)
              owner.define_method(name, &block)
            end
          end
        RUBY
        base_ruby: "def self.pluralize = __store\n  Attr.redefine(self, :__store, 1)"
      )
      runner = Steep::Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!

      typing = checked(project, current_dir + "app/attr.rb")
      call = typing.method_calls.keys.find { |node| node.children[1] == :redefine && node.children[2]&.type == :self }
      assert_equal "singleton(::Base)", typing.self_type_of_call(node: call).to_s
    end
  end

  def test_a_found_block_reports_only_what_the_method_it_defines_finds
    in_tmpdir do
      project = store_project(
        store_rbs: "def self.__store: () -> untyped\n  def self.__store=: (untyped) -> untyped",
        attr_ruby: <<~'RUBY',
          module Attr
            def self.redefine(owner, name, value)
              redefine_method(owner.singleton_class, name) { value }
              redefine_method(owner.singleton_class, "#{name}=") do |new_value|
                pluralize
                1 + ""
                Attr.redefine(self, name, new_value)
              end
            end

            def self.redefine_method(owner, name, &block)
              owner.define_method(name, &block)
            end
          end
        RUBY
        base_ruby: "def self.pluralize = __store\n  Attr.redefine(self, :__store, 1)"
      )
      runner = Steep::Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!

      typing = checked(project, current_dir + "app/attr.rb")
      assert_equal [[6, "1 + \"\""]], typing.errors.map { |error| [error.location.line, error.location.source] }
    end
  end

  def test_a_block_parameter_of_the_same_name_does_not_assign_the_local
    in_tmpdir do
      project = store_project(
        store_rbs: "def self.__store: () -> untyped\n  def self.__other: (untyped) -> untyped",
        attr_ruby: FORWARDED.sub("redefine_method(owner.singleton_class, name) { value }", "redefine_method(owner.singleton_class, name) { value }\n    redefine_method(owner.singleton_class, :__other) { |value| value = 2 }"),
        base_ruby: "def self.pluralize = __store\n  Attr.redefine(self, :__store, 1)"
      )
      methods = Steep::Specializations::Runner.new(project).run

      assert_equal ["(1 | 2)"], methods.fetch("Base.__store").values.uniq
    end
  end

  def defined_keys(attr_ruby: FORWARDED, base_ruby: "def self.pluralize = 1\n  Attr.redefine(self, :__store, 1)", store_rbs: "")
    runner = Steep::Specializations::Runner.new(store_project(store_rbs: store_rbs, attr_ruby: attr_ruby, base_ruby: base_ruby))
    runner.run
    runner.defined_methods.keys
  end

  def test_a_block_forwarded_anonymously_defines_the_method
    in_tmpdir do
      attr_ruby = FORWARDED.sub("def self.redefine_method(owner, name, &block)\n    owner.define_method(name, &block)", "def self.redefine_method(owner, name, &)\n    owner.define_method(name, &)")

      assert_equal ["Base.__store"], defined_keys(attr_ruby: attr_ruby)
    end
  end

  def test_a_proc_a_local_holds_defines_the_method
    in_tmpdir do
      attr_ruby = FORWARDED.sub("redefine_method(owner.singleton_class, name) { value }", "reader = proc { value }\n    owner.singleton_class.define_method(name, &reader)")

      assert_equal ["Base.__store"], defined_keys(attr_ruby: attr_ruby)
    end
  end

  def test_a_define_method_on_the_implicit_receiver_defines_the_method_on_self
    in_tmpdir do
      base_ruby = "def self.pluralize = 1\n  def self.def_store(name, value) = define_method(name) { value }\n  def_store(:__store, 1)"

      assert_equal ["Base#__store"], defined_keys(base_ruby: base_ruby, store_rbs: "def self.def_store: (Symbol name, untyped value) -> untyped")
    end
  end

  def test_a_define_method_reached_once_per_element_of_an_each_defines_each_method
    in_tmpdir do
      base_ruby = "def self.pluralize = 1\n  def self.stores(*names)\n    names.each { |name| Attr.redefine(self, name, 1) }\n  end\n  stores(:__store, :__other)"

      assert_equal ["Base.__other", "Base.__store"], defined_keys(base_ruby: base_ruby, store_rbs: "def self.stores: (*Symbol names) -> untyped").sort
    end
  end
end

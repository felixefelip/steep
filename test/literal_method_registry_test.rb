require_relative "test_helper"

class LiteralMethodRegistryTest < Minitest::Test
  Registry = Steep::Project::LiteralMethodRegistry

  def registry_for(source)
    Registry.new.tap { |registry| registry.ingest_source(source, path_name: "test.rb") }
  end

  def test_records_direct_core_redefinitions
    registry = registry_for(<<~RUBY)
      class String
        def upcase = "override"
      end

      class Integer
        define_method(:succ) { 0 }
      end
    RUBY

    assert registry.blocked?("::String#upcase")
    assert registry.blocked?("::Integer#succ")
    refute registry.blocked?("::String#downcase")
  end

  def test_records_a_reopened_array
    registry = registry_for(<<~RUBY)
      class Array
        def join(separator = nil) = "override"
      end
    RUBY

    assert registry.blocked?("::Array#join")
    refute registry.blocked?("::Array#first")
  end

  def test_a_mixin_hook_taints_what_it_is_mixed_into
    registry = registry_for(<<~RUBY)
      module Sneaky
        def self.append_features(base)
          base.class_eval { def join(*) = "hijacked" }
          super
        end
      end

      Array.include Sneaky
    RUBY

    assert registry.blocked?("::Array#join")
  end

  def test_a_module_this_index_has_not_read_taints
    assert registry_for("Array.include FromSomeGem").blocked?("::Array#join")
    assert registry_for("Array.include(constant_named_at_runtime)").blocked?("::Array#join")
  end

  def test_a_module_that_mixes_something_further_in_taints
    registry = registry_for(<<~RUBY)
      module Passthrough
        include Whatever
      end

      Array.include Passthrough
    RUBY

    assert registry.blocked?("::Array#join")
  end

  def test_every_module_of_a_mixin_site_is_checked
    registry = registry_for(<<~RUBY)
      module Safe
        def to_choice_sentence = self
      end

      module Sneaky
        def self.included(base)
          base.class_eval { def join(*) = "hijacked" }
        end
      end

      Array.include Safe, Sneaky
    RUBY

    assert registry.blocked?("::Array#join")
  end

  def test_a_hook_built_by_alias_or_dynamically_counts_as_one
    aliased = registry_for(<<~RUBY)
      module Aliased
        class << self
          def install(base) = base.class_eval { def join(*) = "hijacked" }
          alias included install
        end
      end

      Array.include Aliased
    RUBY

    dynamic = registry_for(<<~RUBY)
      module Dynamic
        define_method(hook_name) { |base| base }
      end

      Array.include Dynamic
    RUBY

    assert aliased.blocked?("::Array#join")
    assert dynamic.blocked?("::Array#join")
  end

  def test_an_ambiguous_constant_is_not_resolved_by_ingestion_order
    registry = Registry.new
    registry.ingest_source(<<~RUBY, path_name: "top_level.rb")
      module Candidate
        def to_choice_sentence = self
      end
    RUBY
    registry.ingest_source(<<~RUBY, path_name: "site.rb")
      module Outer
        Array.include Candidate
      end
    RUBY
    # Read last, and the one Ruby would actually find from inside `Outer`.
    registry.ingest_source(<<~RUBY, path_name: "nested.rb")
      module Outer
        module Candidate
          def self.included(base) = base.class_eval { def join(*) = "hijacked" }
        end
      end
    RUBY

    assert registry.blocked?("::Array#join")
  end

  def test_dup_has_an_independent_blocked_set
    original = Registry.new
    copy = original.dup

    copy.ingest_source("class String; def upcase = 'override'; end", path_name: "copy.rb")

    assert copy.blocked?("::String#upcase")
    refute original.blocked?("::String#upcase")
  end

  def test_records_dynamic_reopenings_and_refinements
    registry = registry_for(<<~RUBY)
      module Wrapper
        String.class_eval do
          def strip = self
        end

        refine Integer do
          def abs = 0
        end
      end
    RUBY

    assert registry.blocked?("::String#strip")
    assert registry.blocked?("::Integer#abs")
  end

  def test_taints_opaque_eval_and_records_method_table_mutators
    registry = registry_for(<<~RUBY)
      String.class_eval("def upcase = 'override'")
      Integer.alias_method(:succ, :abs)
      Symbol.remove_method(:to_s)
    RUBY

    Steep::LiteralIntrinsics.method_keys_for("String").each do |method_name|
      assert registry.blocked?(method_name), method_name
    end
    assert registry.blocked?("::Integer#succ")
    assert registry.blocked?("::Symbol#to_s")
  end

  def test_records_mutations_dispatched_through_literal_send
    registry = registry_for(<<~RUBY)
      String.send(:define_method, :upcase) { "override" }
      Integer.__send__("alias_method", :succ, :abs)
      Symbol.public_send(:class_eval) do
        def to_s = "override"
      end
    RUBY

    assert registry.blocked?("::String#upcase")
    assert registry.blocked?("::Integer#succ")
    assert registry.blocked?("::Symbol#to_s")
  end

  def test_fails_closed_when_a_source_cannot_be_parsed
    registry = registry_for("class String\n  def")

    Steep::LiteralIntrinsics::ENTRIES.each_key do |method_name|
      assert registry.blocked?(method_name), method_name
    end
  end

  def test_project_build_does_not_parse_erb_as_ruby
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      project = Steep::Project.new(steepfile_path: root + "Steepfile")
      Steep::Project::DSL.parse(project, <<~STEEPFILE)
        target :app do
          check "app/views/**/*.erb"
        end
      STEEPFILE

      (root + "app/views").mkpath
      (root + "app/views/show.html.erb").write("<%= \"hello\".upcase %>")

      assert Registry.build(project).empty?
    end
  end

  def test_from_paths_does_not_parse_erb_as_ruby
    Dir.mktmpdir do |dir|
      template = Pathname(dir) + "show.html.erb"
      template.write("<%= \"hello\".upcase %>")

      assert Registry.from_paths([template]).empty?
    end
  end

  def test_taints_all_intrinsics_when_lookup_is_mutated
    registry = registry_for(<<~RUBY)
      module CoreOverrides
      end

      String.prepend(CoreOverrides)
    RUBY

    Steep::LiteralIntrinsics.method_keys_for("String").each do |method_name|
      assert registry.blocked?(method_name), method_name
    end
  end

  def test_an_included_module_does_not_shadow_an_entry
    registry = registry_for(<<~RUBY)
      module Conversions
        def join(*) = "hijacked"
      end

      Array.include Conversions
      Integer.extend Conversions
    RUBY

    # Neither reaches an instance method the class defines itself — `include`
    # lands below it, `extend` lands on the singleton.
    refute registry.blocked?("::Array#join")
    refute registry.blocked?("::Integer#succ")
  end

  def test_does_not_confuse_a_nested_constant_with_the_core_class
    registry = registry_for(<<~RUBY)
      module Application
        class String
          def upcase = "nested"
        end
      end
    RUBY

    refute registry.blocked?("::String#upcase")
  end
end

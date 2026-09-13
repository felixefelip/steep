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
          check "app"
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

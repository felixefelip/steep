require_relative "test_helper"

class ScalarConstantsTest < Minitest::Test
  include TestHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  RBS = <<~RBS
    module Engine
      LEVEL: Integer
    end
    class Mri
    end
    class Java
    end
  RBS

  RUNTIME = <<~RUBY
    # frozen_string_literal: true
    RUBY_ENGINE = "ruby"
  RUBY

  ENGINE = <<~RUBY
    module Engine
      LEVEL = 2
    end
  RUBY

  def types_of(source_text, others, quiet: true)
    registry = Steep::Project::ConstructorBindingRegistry.new
    others.each_with_index { |other, index| registry.ingest_source(other, path_name: "other#{index}.rb") }
    registry.ingest_source(source_text, path_name: "app.rb")

    with_checker({ "app.rbs" => RBS }, with_stdlib: true) do |checker|
      source = parse_ruby(source_text)
      with_standard_construction(checker, source, constructor_bindings: registry) do |construction, typing|
        pair = construction.synthesize(source.node)

        assert_no_error typing if quiet
        return pair.context.type_env.local_variable_types.transform_values { |(type, _)| type.to_s }
      end
    end
  end

  def test_a_constant_another_file_writes_once_as_a_frozen_scalar_folds_where_it_is_read
    types = types_of(<<~RUBY, [RUNTIME, ENGINE])
      cruby = RUBY_ENGINE == "ruby"
      jruby = RUBY_ENGINE == "jruby"
      level = Engine::LEVEL + 1
    RUBY

    assert_equal({ cruby: "true", jruby: "false", level: "3" }, types.slice(:cruby, :jruby, :level))
  end

  def test_declines_a_constant_that_may_hold_another_value
    {
      "a string its file does not freeze" => [RUNTIME.sub("# frozen_string_literal: true\n", "")],
      "written by two files" => [RUNTIME, RUNTIME],
      "written under a condition" => ["# frozen_string_literal: true\nRUBY_ENGINE = \"ruby\" if ENV[\"X\"]\n"]
    }.each do |label, others|
      types = types_of(%(cruby = RUBY_ENGINE == "ruby"\n), others)

      refute_equal "true", types[:cruby], label
    end
  end

  def test_a_case_with_no_subject_takes_only_the_branches_its_tests_leave
    types = types_of(<<~RUBY, [RUNTIME], quiet: false)
      picked = case
               when RUBY_ENGINE == "jruby" then Java
               when RUBY_ENGINE == "ruby" then Mri
               end
      first = case
              when RUBY_ENGINE == "ruby" then Mri
              when RUBY_ENGINE == "jruby" then Java
              else nil
              end
      ruled_out = case
                  when RUBY_ENGINE == "ruby" then Mri
                  when ENV["JAVA"] then Java
                  end
    RUBY

    assert_equal({ picked: "singleton(::Mri)", first: "singleton(::Mri)", ruled_out: "singleton(::Mri)" }, types.slice(:picked, :first, :ruled_out))
  end
end

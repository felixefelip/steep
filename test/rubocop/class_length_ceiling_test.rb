require "minitest/autorun"
require "rubocop"
require_relative "../../.rubocop/class_length_ceiling"

class ClassLengthCeilingTest < Minitest::Test
  COP_CONFIG = { "Enabled" => true, "Max" => 3, "CountAsOne" => [], "Ceilings" => { "lib/big.rb" => 5 } }.freeze

  def offenses(source, path)
    defaults = RuboCop::ConfigLoader.default_configuration.to_h
    config = RuboCop::Config.new(
      defaults.merge(
        "AllCops" => defaults["AllCops"].merge("DisplayCopNames" => false),
        "Project/ClassLengthCeiling" => COP_CONFIG
      ),
      "#{Dir.pwd}/.rubocop.yml"
    )
    processed_source = RuboCop::ProcessedSource.new(source, 3.3, path)
    cop = RuboCop::Cop::Project::ClassLengthCeiling.new(config)
    RuboCop::Cop::Commissioner.new([cop]).investigate(processed_source).offenses.map(&:message)
  end

  def class_of(lines, name: "Big")
    "class #{name}\n#{(1..lines).map { |i| "  a#{i} = #{i}\n" }.join}end\n"
  end

  def test_holds_an_unlisted_file_to_max
    assert_equal ["Class has too many lines. [4/3]"], offenses(class_of(4, name: "Other"), "lib/other.rb")
  end

  def test_lets_a_listed_files_largest_class_sit_at_its_ceiling
    assert_empty offenses(class_of(5), "lib/big.rb")
  end

  def test_flags_a_listed_class_that_grew_past_its_ceiling
    assert_equal ["Class has too many lines. [6/5]"], offenses(class_of(6), "lib/big.rb")
  end

  def test_asks_for_the_ceiling_to_come_down_when_the_class_shrank
    assert_equal(
      ["Largest class shrank to 4 lines; lower this file's ceiling in .rubocop.yml from 5."],
      offenses(class_of(4), "lib/big.rb")
    )
  end

  def test_asks_for_the_ceiling_to_go_when_the_class_is_back_under_max
    assert_equal(
      ["No class here is over 3 lines any more; remove this file's ceiling from .rubocop.yml."],
      offenses(class_of(1), "lib/big.rb")
    )
  end

  def test_judges_a_stale_ceiling_by_the_files_largest_class_not_a_smaller_one_beside_it
    assert_empty offenses("#{class_of(1, name: "Small")}\n#{class_of(5)}", "lib/big.rb")
  end
end

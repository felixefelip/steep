require_relative "test_helper"

class TakenAnswersTest < Minitest::Test
  def taken(source)
    Steep::TypeInference::TakenAnswers.of(Steep::Source.new_parser.parse(Parser::Source::Buffer.new("a.rb", source: source)))
  end

  def test_a_statement_whose_value_nothing_reads_takes_no_answer
    names = taken("class A\n  def run\n    dropped\n    answered\n  end\nend\n")

    refute_includes names, :dropped
    assert_includes names, :answered
  end

  def test_an_initialize_takes_no_answer_of_its_last_statement
    refute_includes taken("class A\n  def initialize\n    dropped\n  end\nend\n"), :dropped
  end

  def test_a_value_assigned_handed_on_or_tested_is_taken
    ["x = read", "write(read)", "if read then 1 end\nnil", "read.size"].each do |body|
      assert_includes taken("def run\n  #{body}\nend\n"), :read, body
    end
  end

  def test_a_name_written_as_a_symbol_or_a_string_is_taken
    assert_includes taken("def run\n  send(:read)\n  nil\nend\n"), :read
    assert_includes taken("def run\n  public_send(\"read\")\n  nil\nend\n"), :read
  end
end

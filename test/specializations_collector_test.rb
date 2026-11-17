require_relative "test_helper"

class SpecializationsCollectorTest < Minitest::Test
  def test_a_call_the_checker_synthesizes_is_in_no_definition
    source = Steep::Source.parse("class A\n  def self.a = 1\nend\n", path: Pathname("a.rb"), factory: nil)
    definitions = Steep::Specializations::Collector.definitions(source).to_a
    synthesized = Parser::AST::Node.new(:send, [nil, :inherited])

    assert_nil Steep::Specializations::Collector.enclosing(definitions, synthesized)
  end
end

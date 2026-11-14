require_relative "test_helper"
require_relative "specializations_project_helper"

class SpecializationsYieldReplayTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  Specializations = Steep::Specializations

  RBS = <<~RBS
    class Keys
      def self.ident: (Symbol key) { (Symbol) -> Symbol } -> Symbol
      def self.named: (Symbol key) ?{ (Symbol, Symbol) -> String } -> String
    end
    class Caller
      def ident: () -> Symbol
      def named: () -> String
      def named_again: () -> String
      def suffixed: () -> String
    end
  RBS

  def specialize(project, generations: 3)
    generations.times do
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!
    end
  end

  def caller_types(body)
    in_tmpdir do
      write("sig/keys.rbs", RBS)
      write("app/keys.rb", <<~RUBY)
        class Keys
          def self.ident(key) = yield(key)
          def self.named(key, &block) = block.call(:map, key)
        end

        class Caller
          #{body}
        end
      RUBY
      project = setup_project
      specialize(project)
      yield project if block_given?
      body_types(project, current_dir + "app/keys.rb")
    end
  end

  def test_a_yield_answers_what_the_block_makes_of_the_yielded_value
    assert_equal ":missing", caller_types("def ident = Keys.ident(:missing) { |key| key }").fetch("ident")
  end

  def test_a_call_of_the_block_parameter_answers_for_each_parameter
    assert_equal '"missing"', caller_types("def named = Keys.named(:missing) { |_map, key| key.to_s }").fetch("named")
  end

  def test_two_calls_writing_the_same_block_share_one_entry
    body = <<~RUBY
      def named = Keys.named(:missing) { |_map, key| key.to_s }
      def named_again = Keys.named(:missing) { |_map, key| key.to_s }
    RUBY
    entries = nil
    types = caller_types(body) { |project| entries = Specializations::Runner.new(project).run.fetch("Keys.named") }

    assert_equal(['"missing"'], entries.values)
    assert_match(/\A\(:missing\) &\{\h{16}\}\z/, entries.keys.first)
    assert_equal '"missing"', types.fetch("named_again")
  end

  def test_a_block_reading_a_local_of_its_scope_answers_the_declaration
    body = <<~RUBY
      def suffixed
        suffix = "!"
        Keys.named(:missing) { |_map, key| key.to_s + suffix }
      end
    RUBY
    assert_equal "::String", caller_types(body).fetch("suffixed")
  end

  def test_a_block_adding_to_a_local_of_its_scope_answers_the_declaration
    body = <<~RUBY
      def suffixed
        seen = "seen: "
        Keys.named(:missing) { |_map, key| seen += key.to_s }
      end
    RUBY
    assert_equal "::String", caller_types(body).fetch("suffixed")
  end
end

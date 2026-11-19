require_relative "test_helper"
require_relative "specializations_project_helper"

class SpecializationsUntypedUnionTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def recorded
    in_tmpdir do
      write("sig/box.rbs", <<~RBS)
        class Box[V]
          def fetch: (untyped key) -> V
                   | [D] (untyped key, D default_value) -> (V | D)
                   | [T, D] (T key) { (T key) -> D } -> (V | D)
          def lookup: (untyped key, untyped missing) -> untyped
        end
        class Caller
          def box: () -> Box[untyped]
          def read: () -> untyped
          def read_with_default: () -> untyped
        end
      RBS
      write("app/box.rb", <<~RUBY)
        class Box
          MISSING = Object.new

          def fetch(key, default_value = MISSING)
            if MISSING != (value = lookup(key, MISSING))
              value
            elsif block_given?
              yield key
            elsif MISSING != default_value
              default_value
            end
          end

          def lookup(key, missing) = missing
        end

        class Caller
          def read = box.fetch(:a) { |key| key }
          def read_with_default = box.fetch(:b, 1)
        end
      RUBY
      project = setup_project
      runner = Steep::Specializations::Runner.new(project)
      runner.run
    end
  end

  def test_an_answer_keeps_the_known_members_of_a_union_with_untyped
    answers = recorded.fetch("Box#fetch").transform_keys(&:to_s)

    assert_equal "(untyped | :a)", answers.fetch("(:a) &{3fcdb7c7562bfddd}")
    assert_equal "(untyped | 1 | nil)", answers.fetch("(:b, 1)")
  end

  def test_a_variable_made_up_for_a_call_is_read_as_untyped
    fresh = Steep::AST::Types::Var.fresh(:D)
    rigid = Steep::AST::Types::Var.new(name: :K)
    type = Steep::AST::Types::Union.build(types: [fresh, rigid, Steep::AST::Builtin.nil_type])

    assert_equal "(untyped | K | nil)", Steep::Specializations.unsolved_as_untyped(type).to_s
  end
end

module Steep
  module TypeInference
    # What `a || b` / `a && b` answer as a condition, keeping the arms their
    # operands rule out. The env each side carries is not enough:
    # `LogicTypeInterpreter#evaluate_node` reads reachability off this type, and
    # `word == "x"` stays a logic type even where narrowing has decided it.
    module ShortCircuit
      class << self
        def or_type(type, left_truthy, left_falsy, right_truthy, right_falsy)
          decided_type(type, [left_truthy, (right_truthy unless left_falsy.unreachable)], right_falsy)
        end

        def and_type(type, left_truthy, left_falsy, right_truthy, right_falsy)
          decided_type(type, [left_falsy, (right_falsy unless left_truthy.unreachable)], right_truthy)
        end

        private

        # `exits` are the results that end the operator early, `other` the one
        # only the right operand reaches.
        def decided_type(type, exits, other)
          reachable = exits.compact.reject(&:unreachable)
          return other.type if reachable.empty?
          return AST::Types::Union.build(types: reachable.map(&:type)) if other.unreachable

          type
        end
      end
    end
  end
end

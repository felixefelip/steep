module Steep
  module TypeInference
    class ConstructorBindingAnalyzer
      # Where a method's value may be `self`:
      #
      # - `exposes_self_besides_return`: `Body#exposes_self` but for a `self` it
      #   returns, which its caller is handed as the call's value;
      # - `returns_self`: whether it may return `self`, or a `super`'s or a
      #   block's value, which this does not follow;
      # - `returned_sends`: the methods it calls on `self` whose value it may
      #   return.
      module SelfReturns
        module_function

        def facts(body)
          returned = [] #: Array[::Parser::AST::Node]
          Accumulators::ReturnedValues.each_value(body, logic: true) { |node| returned << node }
          sends = returned.filter_map { |node| node.children[1] if ObjectStates.on_self?(node) }
          {
            exposes_self_besides_return: ConstructorBindingAnalyzer.self_exposures(body).any? { |node| node.type != :self || returned.none? { |value| value.equal?(node) } },
            returns_self: returned.any? { |node| %i[self super zsuper block numblock].include?(node.type) },
            returned_sends: sends.to_set
          }
        end
      end
    end
  end
end

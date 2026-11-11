module Steep
  module ObjectStates
    # A call that may answer the object it is made on gives that object a
    # second name wherever its value is taken:
    #
    #   map.clear                # discarded: `map` is still the only name
    #   other = map.clear        # `other` is `map`; a write through it is one
    #                            # `map`'s state does not follow
    #
    # `TypeInference::HeldLocals` reads how a variable is mentioned, not what a
    # call made on it answers, so the variable keeps only what holds under any
    # name once such a call's value is taken. `x[k] = v` and `x.y = v` are
    # worth `v`, whatever the method answers.
    module ReturnedSelf
      COMPARISONS = %i[== != <= >= ===].freeze

      module_function

      def aliased?(constr, node, receiver_type, method_name)
        return false if method_name.end_with?("=") && !COMPARISONS.include?(method_name)
        return false if constr.method_context&.value_uses&.left?(node)

        members = receiver_type.is_a?(AST::Types::Union) ? receiver_type.types : [receiver_type]
        members.any? { |member| (state = ObjectStates.state_in(member)) && may_return_self?(constr, state.back_type, method_name) }
      end

      # Whether `method_name` may answer `self`: its body returns it, or a
      # value this does not follow, or calls on `self` a method that may. One
      # with no body to read may.
      def may_return_self?(constr, instance, method_name, visiting = [])
        _, body = ObjectStates.resolved_body(constr, instance, method_name)
        return true if body.nil?

        body.returns_self || body.returned_sends.any? do |name|
          !visiting.include?(name) && may_return_self?(constr, instance, name, [*visiting, method_name])
        end
      end
    end
  end
end

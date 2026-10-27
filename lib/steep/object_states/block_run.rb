module Steep
  module ObjectStates
    # A block a method runs exactly once before it returns
    # (`Postconditions::RunsBlock`) leaves `self`'s ivars as it left them
    # (felixefelip/steep#370):
    #
    #   def []=(key, value)
    #     @write_lock.synchronize { super }   # what `super` stores holds after the call
    #   end
    #
    # One a method may run any other number of times leaves each ivar it
    # changes as it was before the call or as one pass left it, the rule a
    # `while` body follows. Only where the call is made on another object and
    # is not handed `self`: its body then has no way to change `self` around
    # the block.
    module BlockRun
      module_function

      def after(constr, node, receiver_type, method_name)
        return constr unless Accumulators::LAMBDA_BODIES.include?(node.type) && node.children[2]

        left = constr.typing.block_exit_of(node: node) or return constr
        entered = constr.context.type_env
        changed = left.instance_variable_types.keys.reject { |ivar| left[ivar] == entered[ivar] }
        return constr if changed.empty?

        once = !Tap.jumps?(node.children[2]) && runs_once?(constr, receiver_type, method_name)
        constr.update_type_env do |env|
          env.refine_types(instance_variable_types: changed.to_h { |ivar| [ivar, once ? left[ivar] : either(entered, left, ivar)] })
        end
      end

      def either(entered, left, ivar)
        AST::Types::Union.build(types: [entered[ivar] || entered.declared_instance_variable_type(ivar) || AST::Builtin.nil_type, left[ivar]])
      end

      def runs_once?(constr, receiver_type, method_name)
        receiver = ObjectStates.state_in(receiver_type)&.back_type || receiver_type
        return false unless receiver.is_a?(AST::Types::Name::Instance) || receiver.is_a?(AST::Types::Name::Singleton)

        owner, = ObjectStates.resolved_body(constr, receiver, method_name)
        owner && constr.postconditions.lookup_instance(owner, method_name)&.runs_block || false
      end
    end
  end
end

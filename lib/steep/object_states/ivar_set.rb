module Steep
  module ObjectStates
    # `klass.instance_variable_set(:@x, value)`, the core method called on a
    # class object other than `self`, writes that class's `@x`: where the
    # checker follows the class's state, it holds the value written.
    module IvarSet
      def self.typed(constr, node, receiver_type, method_name, arguments)
        ivar_node, value = arguments
        return unless method_name == :instance_variable_set && node.type == :send && arguments.size == 2
        return unless receiver_type.is_a?(AST::Types::Name::Singleton) && receiver_type != constr.self_type
        return unless ivar_node.type == :sym && ivar_node.children[0].to_s.match?(/\A@[^@]/) && constr.core_send?(receiver_type, method_name)

        written(constr, node, ivar_node, value, receiver_type.name)
      end

      def self.written(constr, node, ivar_node, value, name)
        ivar = ivar_node.children[0]
        type, constr = constr.synthesize(value)
        operand = Specializations::Arguments.written_record(value, constr.typing, nil) || Specializations::Arguments.written_array(value, constr.typing) ||
                  constr.literal_operand_type(value, type)
        constr = constr.update_type_env do |env|
          ivars = env.class_states.fetch(name, {}).except(ivar)
          ivars = ivars.merge(ivar => operand) if ObjectStates.state_value?(operand) || ObjectStates.state_in(operand)
          env.update(class_states: ivars.empty? ? env.class_states.except(name) : env.class_states.merge(name => ivars))
        end
        _, constr = constr.add_typing(ivar_node, type: AST::Types::Literal.new(value: ivar))
        constr.add_typing(node, type: type)
      end
    end
  end
end

module Steep
  module ObjectStates
    # What `self` holds in a body checked for its receiver's contents
    # (`Specializations::Arguments#self_ivars`), for a reader called on it to
    # answer, as an `ObjectState` would for any other receiver.
    module EnteredSelf
      def self.state(constr, receiver_type, call)
        self_type = constr.self_type
        return unless receiver_type.is_a?(AST::Types::Self) && self_type.is_a?(AST::Types::Name::Instance)

        ivars = ObjectStates.call_ivars(constr, call)
        AST::Types::ObjectState.new(back_type: self_type, ivars: ivars) unless ivars.empty?
      end

      # An ivar the body was entered with holds the value assigned as
      # written: a hash as the record it writes, a literal as itself.
      def self.assigned(pair, ivar, value)
        constr = pair.constr
        def_node = constr.method_context&.node
        return pair unless def_node && constr.specialization_arguments(def_node)&.self_ivars&.key?(ivar)

        operand = Specializations::Arguments.written_record(value, constr.typing, nil) || constr.literal_operand_type(value, pair.type)
        return pair unless ObjectStates.state_value?(operand)

        pair.with(constr: constr.update_type_env { |env| env.refine_types(instance_variable_types: { ivar => operand }) })
      end
    end
  end
end

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
    end
  end
end

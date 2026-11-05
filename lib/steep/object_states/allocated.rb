module Steep
  module ObjectStates
    # What `Klass.allocate` holds: no `initialize` ran on it, so every ivar
    # the class declares is unset.
    module Allocated
      def self.state(constr, instance)
        ivars = constr.checker.factory.definition_builder.build_instance(instance.name).instance_variables
        AST::Types::ObjectState.new(back_type: instance, ivars: ivars.keys.to_h { |ivar| [ivar, AST::Builtin.nil_type] })
      rescue RBS::BaseError
        nil
      end
    end
  end
end

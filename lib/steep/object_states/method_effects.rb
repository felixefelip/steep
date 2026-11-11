module Steep
  module ObjectStates
    # `ObjectStates.method_effect`, computed once per method across every copy
    # of a store: it reads the definitions, the constructor bindings, the
    # postconditions and the intrinsic tables, never the flow.
    module MethodEffects
      module_function

      def of(constr, instance, method_name)
        key = [:method_effect, constr.checker, constr.constructor_bindings, constr.postconditions, constr.literal_method_registry, instance, method_name]
        constr.specializations.keep(key) { ObjectStates.method_effect(constr, instance, method_name) }
      end
    end
  end
end

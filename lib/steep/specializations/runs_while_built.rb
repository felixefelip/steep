module Steep
  module Specializations
    # Whether a method runs only while an object of `target` is built. A call
    # whose receiver can be none of its values says nothing of that.
    module RunsWhileBuilt
      class << self
        def only?(constr, target, name, visiting = Set[])
          registry = constr.constructor_bindings
          return true if Project::ConstructorBindingRegistry::INITIALIZERS.include?(name) || registry.initializing?(name)
          return false if visiting.include?(name) || !registry.used_names.include?(name)

          calls = Receivers.calls_on(constr, name, target)
          !calls.empty? && calls.all? do |call|
            registry.literal_receiver?(call) || (call.on_self && !call.singleton && !call.enclosing.nil? && only?(constr, target, call.enclosing, visiting | [name]))
          end
        end
      end
    end
  end
end

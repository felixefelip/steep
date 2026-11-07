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
            registry.literal_receiver?(call, related: related_to(constr, call.owner)) || (call.on_self && !call.singleton && !call.enclosing.nil? && only?(constr, target, call.enclosing, visiting | [name]))
          end
        end

        # Whether two classes can share an ivar: one descends from the other.
        def related_to(constr, owner)
          ->(name) { owner.to_s.empty? || descends?(constr, owner, name) || descends?(constr, name, owner) }
        end

        private

        def descends?(constr, name, ancestor)
          constr.checker.factory.definition_builder.ancestor_builder.instance_ancestors(RBS::TypeName.parse("::#{name}")).ancestors.any? do |each|
            each.name.to_s == "::#{ancestor}"
          end
        rescue RBS::BaseError, RuntimeError
          true
        end
      end
    end
  end
end

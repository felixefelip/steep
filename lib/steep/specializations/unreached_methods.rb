module Steep
  module Specializations
    # Whether no call of the project may run a method on a value of `target`,
    # and the runtime does not call it on its own either: the project names it
    # nowhere, or every call of it has a receiver the checker typed as no value
    # of `target` (`Receivers.calls_on`), or is made inside a method that is
    # itself unreached. A call in a class body, a block or a method no type
    # names runs; a name `index_uses` did not look for may be called anywhere;
    # a cycle of methods is taken as reached.
    module UnreachedMethods
      class << self
        def unreached?(constr, target, name, visiting = Set[])
          return false if ObjectStates::ClassMemos.called_implicitly?(constr, [name])

          registry = constr.constructor_bindings
          calls = registry.calls_of(name)
          return true unless registry.may_call?(name)

          !calls.empty? && Receivers.calls_on(constr, name, target).all? { |call| inside_unreached?(constr, call, visiting) }
        end

        private

        def inside_unreached?(constr, call, visiting)
          method = call.enclosing or return false
          return false if call.owner.to_s.empty? || initializing?(constr, method)

          key = [call.owner, method, call.singleton]
          return false if visiting.include?(key)

          name = RBS::TypeName.parse("::#{call.owner}")
          return false unless constr.checker.factory.definition_builder.env.module_class_entry(name)

          owner = call.singleton ? AST::Types::Name::Singleton.new(name: name) : AST::Types::Name::Instance.new(name: name, args: [])
          unreached?(constr, owner, method, visiting | [key])
        rescue RBS::BaseError
          false
        end

        def initializing?(constr, method)
          Project::ConstructorBindingRegistry::INITIALIZERS.include?(method) || constr.constructor_bindings.initializing?(method)
        end
      end
    end
  end
end

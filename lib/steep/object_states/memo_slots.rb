module Steep
  module ObjectStates
    # Whether the slot a class's memo keeps its object in is one no other code
    # may set: the memo `method_name` of `owner`, where there is one.
    module MemoSlots
      class << self
        def written_only_by?(constr, singleton, slot, owner, method_name)
          return class_variable_written_only_by?(constr, slot, owner, method_name) if slot.start_with?("@@")

          definition = constr.checker.factory.definition_builder.build_singleton(singleton.name)
          definition.ancestors.ancestors.none? do |ancestor|
            constr.postconditions.may_write?(ancestor.name.to_s, slot, except: ancestor.name == owner ? method_name : nil)
          end
        rescue RBS::BaseError
          false
        end

        private

        # A class variable is one slot for the class whose code names it, its
        # subclasses and its ancestors that name it too, so a write anywhere in
        # that line counts: the memo is the only one of `method_name`, no class
        # body assigns it anything but `nil`, and every other method that
        # assigns it is one no code calls.
        def class_variable_written_only_by?(constr, cvar, owner, method_name)
          registry = constr.constructor_bindings
          writes = registry.cvar_writes_of(Set[cvar]).select { |class_name, _, _| shares_slot?(constr, class_name, owner) }
          memos, others = writes.partition { |_, name, memo| memo && name == method_name }
          memos.size == 1 && others.all? { |_, name, _| name && name != method_name && registry.uses_of(name).empty? }
        end

        def shares_slot?(constr, class_name, owner)
          builder = constr.checker.factory.definition_builder
          name = RBS::TypeName.parse("::#{class_name}")
          return true unless owner && builder.env.module_class_entry(name)

          [[name, owner], [owner, name]].any? { |sub, sup| builder.build_instance(sub).ancestors.ancestors.any? { |ancestor| ancestor.name == sup } }
        rescue RBS::BaseError
          true
        end
      end
    end
  end
end

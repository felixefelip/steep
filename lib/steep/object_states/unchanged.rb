module Steep
  module ObjectStates
    # Calls that change nothing any object holds: a string eval that only
    # defines methods, and a call that runs no code the program holds
    # (felixefelip/steep#334). A method with no body here cannot run a memo's
    # writer, so a `nil` memo is still `nil` after it.
    module Unchanged
      # Core and gem methods that run code the program holds anyway: by name,
      # through a hook, or by writing an ivar of the object they are handed.
      CALLING_BACK = Set[
        :send, :__send__, :public_send, :instance_exec, :instance_eval, :class_exec, :class_eval, :module_exec, :module_eval,
        :define_method, :define_singleton_method, :instance_variable_set, :remove_instance_variable,
        :method, :public_method, :instance_method, :new, :allocate, :include, :extend, :prepend
      ].freeze

      CALLABLES = [RBS::TypeName.parse("::Proc"), RBS::TypeName.parse("::Method")].freeze

      class << self
        def call?(constr, node)
          Specializations::Evals.defines_only?(constr.typing, node) || runs_no_program?(constr, node)
        end

        private

        # A call whose method has no body here, outside CALLING_BACK, handed
        # nothing to run.
        def runs_no_program?(constr, node)
          return false unless %i[send csend].include?(node.type)

          call = ObjectStates.recorded_call(constr, node)
          return false unless call.is_a?(TypeInference::MethodCall::Typed) && !call.method_decls.empty?
          return false if CALLING_BACK.include?(call.method_name)
          return false if node.children.drop(2).any? { |argument| callable?(constr, argument) }

          call.method_decls.none? { |decl| program_body?(constr.constructor_bindings, decl.method_name) }
        end

        def program_body?(registry, name)
          bodies = name.is_a?(SingletonMethodName) ? registry.singleton_method_bodies(name.type_name) : registry.method_bodies(name.type_name)
          bodies.key?(name.method_name)
        end

        def callable?(constr, argument)
          return true if argument.type == :block_pass
          return false unless constr.typing.has_type?(argument)

          type = constr.typing.type_of(node: argument)
          type.is_a?(AST::Types::Proc) || (type.is_a?(AST::Types::Name::Instance) && CALLABLES.include?(type.name))
        end
      end
    end
  end
end

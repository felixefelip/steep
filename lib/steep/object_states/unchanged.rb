module Steep
  module ObjectStates
    # Calls that change nothing any object holds: a string eval that only
    # defines methods, and a call that runs no code the program holds.
    module Unchanged
      # Core methods that run code by name or write an ivar of their receiver.
      REFLECTIVE = Set[
        *LocalReach::DISPATCHES, *LocalReach::METHOD_OBJECTS, *LocalReach::STRING_EVALS,
        *TypeInference::ClassMemoAnalyzer::REFLECTIVE, *TypeInference::ClassMemoAnalyzer::STRING_EVALS
      ].freeze

      # Core methods that run a hook of their receiver, or of its instances
      # for `new`.
      HOOKS = {
        new: :initialize,
        const_set: :const_added,
        attr: :method_added, attr_reader: :method_added, attr_writer: :method_added, attr_accessor: :method_added,
        define_method: :method_added, remove_method: :method_removed, undef_method: :method_undefined
      }.freeze

      # Core methods that run the hooks of the modules they are handed.
      MIXINS = %i[include extend prepend].freeze

      class << self
        def call?(constr, node)
          Specializations::Evals.defines_only?(constr.typing, node) || runs_no_program?(constr, node)
        end

        private

        def runs_no_program?(constr, node)
          return false unless %i[send csend].include?(node.type)

          call = ObjectStates.recorded_call(constr, node)
          return false unless call.is_a?(TypeInference::MethodCall::Typed)
          return false if REFLECTIVE.include?(call.method_name)

          arguments = node.children.drop(2)
          return false if arguments.any? { |argument| hands_callable?(constr, argument) }

          receiver = call.receiver_type
          receiver = constr.self_type if receiver.is_a?(AST::Types::Self)
          !program_body?(constr, receiver, call.method_name) && !runs_hook?(constr, receiver, call.method_name, arguments)
        end

        # Any ancestor up to the one the declaration names may define the
        # method in Ruby without the RBS placing it there.
        def program_body?(constr, receiver, method_name)
          return true unless receiver.is_a?(AST::Types::Name::Singleton) || receiver.is_a?(AST::Types::Name::Instance)

          builder = constr.checker.factory.definition_builder
          definition = receiver.is_a?(AST::Types::Name::Singleton) ? builder.build_singleton(receiver.name) : builder.build_instance(receiver.name)
          owner = definition.methods[method_name]&.implemented_in or return true
          ancestors = definition.ancestors.ancestors
          index = ancestors.index { |ancestor| ancestor.name == owner } or return true

          ancestors.take(index + 1).any? { |ancestor| ObjectStates.ancestor_defines?(constr.constructor_bindings, ancestor, method_name) }
        rescue RBS::BaseError
          true
        end

        def runs_hook?(constr, receiver, method_name, arguments)
          return !arguments.all? { |argument| inert_module?(constr, argument) } if MIXINS.include?(method_name)

          hook = HOOKS[method_name] or return false
          return true unless receiver.is_a?(AST::Types::Name::Singleton)
          return program_body?(constr, receiver, hook) unless method_name == :new
          # `Class.new(superclass)` runs the superclass's `inherited`.
          return true if [RBS::BuiltinNames::Class.name, RBS::BuiltinNames::Module.name].include?(receiver.name)

          program_body?(constr, AST::Types::Name::Instance.new(name: receiver.name, args: []), hook)
        end

        def inert_module?(constr, argument)
          return false unless constr.typing.has_type?(argument)

          type = constr.typing.type_of(node: argument)
          type.is_a?(AST::Types::Name::Singleton) && constr.constructor_bindings.inert?(type.name.to_s.delete_prefix("::"))
        end

        def hands_callable?(constr, node)
          return false unless node.is_a?(Parser::AST::Node)
          return true if node.type == :block_pass || callable?(constr, node)

          node.children.any? { |child| hands_callable?(constr, child) }
        end

        def callable?(constr, node)
          return false unless constr.typing.has_type?(node)

          type = constr.typing.type_of(node: node)
          type.is_a?(AST::Types::Proc) || AST::Builtin::Proc.instance_type?(type) || AST::Builtin::Method.instance_type?(type)
        end
      end
    end
  end
end

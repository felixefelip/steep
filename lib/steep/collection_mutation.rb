module Steep
  # What `ArrayMutation` and `HashMutation` ask of a call alike.
  module CollectionMutation
    # What any object answers without changing it or handing out its contents.
    OBJECT_READS = (
      %w[!~ class clone dup frozen? instance_of? is_a? itself kind_of? nil? object_id respond_to?]
        .map { |name| "::Kernel##{name}" } +
      %w[! != equal? __id__].map { |name| "::BasicObject##{name}" }
    ).freeze

    class << self
      # Whether every method a call may resolve to is one of `allowed`, and the
      # project replaced none of them.
      def only?(constr, keys, allowed)
        !keys.empty? && keys.all? { |key| allowed.include?(key) && !constr.literal_method_registry.blocked?(key) }
      end

      # Whether a method `self` runs reaches no ivar of it: a core one that
      # touches only its own elements, or that answers from its arguments
      # whatever `self` is (`Array(tags)`), or one of the project's that only
      # reads (`attr_reader`), or the core `allocate`, which runs no method.
      def reaches_no_ivar?(call, constr)
        return false unless resolved?(call)

        key = MethodIdentity.key(call)
        ArrayMutation.elements_only?(call, constr) || HashMutation.elements_only?(call, constr) || allocates?(call, constr, key) ||
          (!key.nil? && LiteralIntrinsics.self_independent?(key, override_registry: constr.literal_method_registry)) ||
          (constr.self_type.is_a?(AST::Types::Name::Base) && !!ObjectStates.method_effect(constr, constr.self_type, call.method_name)&.reads_only)
      end

      # A call whose method was found, even where its arguments do not check
      # against it (`concat` on a generic `self` handed a tuple): what the
      # method touches does not depend on them.
      def resolved?(call)
        (call.is_a?(TypeInference::MethodCall::Typed) || call.is_a?(TypeInference::MethodCall::Error)) && !call.method_decls.empty?
      end

      def allocates?(call, constr, key)
        key == "::Class#allocate" && !ReflectionIntrinsics.fold(
          call: call,
          receiver_type: call.receiver_type.is_a?(AST::Types::Self) ? constr.self_type : call.receiver_type,
          argument_types: [],
          factory: constr.checker.factory,
          override_registry: constr.literal_method_registry
        ).nil?
      end

      # Whether `receiver` reads an ivar whose contents the body was entered
      # with. Its tuple or record is then what it holds: every call that may
      # change it widens it or folds onto it.
      def entered_with?(constr, receiver)
        return false unless receiver&.type == :ivar

        def_node = constr.method_context&.node or return false
        constr.specialization_arguments(def_node)&.self_ivars&.key?(receiver.children[0]) || false
      end

      # Each argument's type as an operand, or nil where one is not typed.
      def operand_types(constr, arguments)
        arguments.map do |argument|
          return nil unless constr.typing.has_type?(argument)

          constr.literal_operand_type(argument, constr.typing.type_of(node: argument))
        end
      end
    end
  end
end

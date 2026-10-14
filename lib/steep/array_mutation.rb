module Steep
  # Which calls leave an array a held object keeps as it was, and what the
  # pushes onto it leave there (felixefelip/steep#205, stage 3).
  #
  # Only for an ivar whose contents the body was entered with — the state of
  # the receiver a specialization checks it under (`Specializations::Arguments#self_ivars`).
  # A tuple any other variable is typed by is a declaration, which says what the
  # array may hold and never what it holds now.
  #
  # Keyed like `StringMutation`, by the method the call resolved to, and watched
  # by the same registry.
  module ArrayMutation
    ENTRIES = (
      # Only reads that answer no element: one handed out is a name a call may
      # change it through. And only what `Array` defines itself, as the
      # registry keys it.
      %w[<=> == all? any? count empty? eql? hash include? inspect intersect? join length none? size to_s]
        .map { |name| "::Array##{name}" } +
      %w[!~ class clone dup frozen? instance_of? is_a? itself kind_of? nil? object_id respond_to?]
        .map { |name| "::Kernel##{name}" } +
      %w[! != equal? __id__].map { |name| "::BasicObject##{name}" }
    ).to_h { |key| [key, true] }.freeze

    IN_PLACE = Set["::Array#prepend", "::Array#unshift", "::Array#push", "::Array#<<"].freeze

    class << self
      # Before a call on `receiver`: the type to dispatch it against, and the
      # ivar it reads holding an array whose contents are not known, where the
      # call may change them and is no push this can follow.
      def widen_receiver(constr, receiver, receiver_type, method_name, private:, block_params:, block_body:)
        return [receiver_type, constr] unless receiver_type.is_a?(AST::Types::Tuple) && entered_with?(constr, receiver)

        keys = array_method_keys(constr, method_name, private: private)
        if block_params || block_body
          return [receiver_type, constr] if reading_iteration?(constr, keys, block_params, block_body)
        elsif preserves?(constr, keys) || foldable?(constr, keys)
          return [receiver_type, constr]
        end

        widened = AST::Builtin::Array.instance_type(element_type(receiver_type))
        [widened, refine(constr, receiver, widened)]
      end

      # After a push onto `receiver`, with no block: the ivar holding what the
      # push leaves, where every operand is known; holding an array whose
      # contents are not known otherwise.
      def fold_in_place(constr, node, receiver, receiver_type, method_name, arguments, type:, private:)
        return [type, constr] unless receiver_type.is_a?(AST::Types::Tuple) && entered_with?(constr, receiver)

        keys = array_method_keys(constr, method_name, private: private)
        return [type, constr] unless foldable?(constr, keys)

        folded = fold(constr, keys.first, receiver_type, arguments)
        constr = refine(constr, receiver, folded || AST::Builtin::Array.instance_type(element_type(receiver_type)))
        folded ? [folded, constr.add_typing(node, type: folded).constr] : [type, constr]
      end

      def watched_keys
        @watched_keys ||= Set.new(ENTRIES.keys) | IN_PLACE
      end

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end

      # Whether `receiver` reads an ivar whose contents the body was entered
      # with. Its tuple is then what it holds: every call that may change it
      # widens it or folds onto it here.
      def entered_with?(constr, receiver)
        return false unless receiver.type == :ivar

        def_node = constr.method_context&.node or return false
        constr.specialization_arguments(def_node)&.self_ivars&.key?(receiver.children[0]) || false
      end

      private

      # An iteration of the core's whose block only reads the elements it is
      # handed, as a use of a class's memo must (`ClassMemoAnalyzer::Use`).
      def reading_iteration?(constr, keys, block_params, block_body)
        registry = constr.literal_method_registry
        return false if keys.empty? || !keys.all? { |key| IterationIntrinsics.entry(key, override_registry: registry) }

        calls = TypeInference::ClassMemoAnalyzer.element_calls_in(block_params, block_body) or return false
        calls.none? { |name| ObjectStates::ClassMemos.element_read_replaced?(constr, name) }
      end

      def preserves?(constr, keys)
        !keys.empty? && keys.all? { |key| ENTRIES.key?(key) && !constr.literal_method_registry.blocked?(key) }
      end

      def foldable?(constr, keys)
        keys.size == 1 && IN_PLACE.include?(keys.first) && !constr.literal_method_registry.blocked?(keys.first)
      end

      def fold(constr, key, receiver_type, arguments)
        argument_types = arguments.map do |argument|
          return nil unless constr.typing.has_type?(argument)

          constr.literal_operand_type(argument, constr.typing.type_of(node: argument))
        end
        LiteralIntrinsics.fold_key(
          key: key, receiver_type: receiver_type, argument_types: argument_types,
          override_registry: constr.literal_method_registry
        )
      end

      def element_type(tuple)
        tuple.types.empty? ? AST::Builtin.any_type : AST::Types::Union.build(types: tuple.types)
      end

      def refine(constr, receiver, type)
        name = receiver.children[0] #: Symbol
        constr.update_type_env { |env| env.refine_types(instance_variable_types: { name => type }) }
      end

      def array_method_keys(constr, method_name, private:)
        interface = constr.calculate_interface(AST::Builtin::Array.instance_type(AST::Builtin.any_type), private: private) or return []
        method = interface.methods[method_name] or return []

        method.overloads
          .flat_map { |overload| overload.method_decls(method_name) }
          .map { |decl| MethodIdentity.normalize(decl.method_name.to_s) }
          .uniq
      end
    end
  end
end

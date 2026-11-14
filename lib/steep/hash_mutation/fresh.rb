module Steep
  # A hash `Hash.new` builds holds nothing yet, whatever its `initialize` is
  # handed: a default value or a default block is not an entry. Written as the
  # value of a variable nothing else names, its state carries the record of
  # what it holds (`ObjectState#contents`), which is followed as a `{}`'s is,
  # with the state's ivars kept beside it.
  module HashMutation
    class << self
      def built(constr, call, node)
        send = node.type == :block ? node.children[0] : node
        return call unless send.type == :send && send.children[1] == :new && call.is_a?(TypeInference::MethodCall::Typed) && ObjectStates.initialize_call?(call)
        return call unless call.receiver_type.is_a?(AST::Types::Name::Singleton) && call.receiver_type.name == AST::Builtin::Hash.module_name
        held = constr.method_context&.held_locals&.held_value?(node) || ObjectStates::HeldIvar.held_ivars(constr)&.held_value?(node)
        return call unless held && constr.constructor_bindings.initializers_for("::Hash").all? { |body| body.self_sends.empty? }

        state = ObjectStates.state_in(call.return_type)
        return call unless state.nil? || state.equal?(call.return_type)

        instance = state&.back_type || call.return_type
        return call unless instance.is_a?(AST::Types::Name::Instance)

        empty = AST::Types::Record.new(elements: {}, required_keys: Set[])
        call.with_return_type(AST::Types::ObjectState.new(back_type: instance, ivars: state&.ivars || {}, contents: empty))
      end

      def widen_receiver(constr, receiver, receiver_type, method_name, private:, block_params:, block_body:)
        record, state = unwrapped(receiver_type)
        type, constr = widen_record(constr, receiver, record, method_name, private: private, block_params: block_params, block_body: block_body)
        [state && type.equal?(record) ? receiver_type : type, constr]
      end

      def fold_in_place(constr, node, receiver, receiver_type, method_name, arguments, type:, private:)
        record, state = unwrapped(receiver_type)
        if state && CollectionMutation.only?(constr, hash_method_keys(constr, method_name, private: private), KEY_READ)
          return held_entry(constr, node, record, arguments, type)
        end

        fold_record(constr, node, receiver, record, method_name, arguments, type: type, private: private)
      end

      # `[]` on a hash's state: what the record holds under a literal key it
      # holds. A key it does not hold is left to the call, since the state may
      # keep a default for it.
      def held_entry(constr, node, record, arguments, type)
        key, = CollectionMutation.operand_types(constr, arguments)
        return [type, constr] unless arguments.size == 1 && literal_key?(key) && record.required_keys.include?(key.value)

        entry = record.elements.fetch(key.value)
        [entry, constr.add_typing(node, type: entry).constr]
      end

      def contents_state?(type) = type.is_a?(AST::Types::ObjectState) && !type.contents.nil?

      # The record a call on a hash's state is dispatched against, and the
      # state it came from.
      def unwrapped(type) = contents_state?(type) ? [type.contents, type] : [type, nil]

      # `type`, the record a call left the hash holding, back in the state it
      # was read off; any other type leaves the state behind.
      def rewrapped(type, state)
        state && type.is_a?(AST::Types::Record) ? state.with_contents(type) : type
      end
    end
  end
end

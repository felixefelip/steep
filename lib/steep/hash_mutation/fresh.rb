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
        return call unless held && constr.constructor_bindings.initializers_for("::Hash").all? { |body| !body.exposes_self && body.self_sends.none? { |name| writes_entries?(constr, name) } }

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
        kept = state && (type.equal?(record) || !(block_params || block_body || CollectionMutation.only?(constr, hash_method_keys(constr, method_name, private: private), WRITES)))
        [kept ? receiver_type : type, constr]
      end

      # A call dispatched against a hash's state reads what it holds in its
      # body (`Arguments#self_contents`); one that answers the state answers a
      # hash whose contents it may have changed.
      def fold_in_place(constr, node, receiver, receiver_type, method_name, arguments, type:, private:)
        record, state = unwrapped(receiver_type)
        keys = hash_method_keys(constr, method_name, private: private)
        return held_entry(constr, node, record, arguments, type) if state && CollectionMutation.only?(constr, keys, KEY_READ)

        type = unknown_contents(constr, receiver) if state && !reads?(constr.literal_method_registry, keys) && ObjectStates.state_in(type) == state

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

      # A read on `self` in a body checked for a hash's contents
      # (`Arguments#self_contents`), answered off them.
      def entered_read(constr, call, node)
        return call unless call.is_a?(TypeInference::MethodCall::Typed) && node.type == :send && (node.children[0].nil? || node.children[0].type == :self)

        record = entered_contents(constr, node) or return call
        keys = hash_method_keys(constr, node.children[1], private: true)
        arguments = node.children.drop(2)
        answer, = queried(constr, node, record, keys, arguments)
        answer ||= held_entry(constr, node, record, arguments, nil).first if CollectionMutation.only?(constr, keys, KEY_READ)
        answer ? call.with_return_type(answer) : call
      end

      # The contents the body was entered with, where nothing it ran before
      # `node` may have changed them.
      def entered_contents(constr, node)
        def_node = constr.method_context&.node or return
        record = constr.specialization_arguments(def_node)&.self_contents or return
        body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
        record if body && untouched_before?(body, node, node.loc.expression.begin_pos)
      end

      # Code that runs again, or may jump back, after `node` has run.
      REPEATING = %i[while until while_post until_post for block numblock rescue ensure].freeze

      def untouched_before?(scope, node, start)
        return true if scope.equal?(node)
        return false if REPEATING.include?(scope.type)

        scope.children.each do |child|
          range = child.is_a?(Parser::AST::Node) && child.loc.expression or next
          return untouched_before?(child, node, start) if range.begin_pos <= start && start < range.end_pos
          return false if range.end_pos <= start && touches_self?(child)
        end
        true
      end

      # Whether `node` may change what `self` holds: a call on it that is not a
      # read, `self` handed on, or code the caller wrote.
      def touches_self?(node)
        return false unless node.is_a?(Parser::AST::Node)

        case node.type
        when :yield, :super, :zsuper, :block_pass, :self then true
        when :send, :csend
          receiver, name, *args = node.children
          on_self = receiver.nil? || receiver.type == :self
          return true if on_self && !READS.include?("::Hash##{name}")

          [*(receiver unless on_self), *args].any? { |child| touches_self?(child) }
        else node.children.any? { |child| touches_self?(child) }
        end
      end

      # Whether a call of `name` on a hash may run one of `Hash`'s methods
      # that is not a read.
      def writes_entries?(constr, name)
        hash_method_keys(constr, name, private: true).any? { |key| key.start_with?("::Hash#") && !READS.include?(key) }
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

module Steep
  module ObjectStates
    # `Kernel#tap` runs its block once, there and then, with the object it was
    # called on, and answers that object (felixefelip/steep#247):
    #
    #   Rules.new.tap { |rules| rules.singular(/s\z/, "") }   # ::Rules{@singulars: [[/s\z/, ""]]}
    #
    # Followed only where the block's parameter is the one name the object has:
    # a `.new` nothing else holds, handed to a parameter the block makes calls
    # through (`TypeInference::HeldLocals`), and a block that finishes where it
    # falls off.
    module Tap
      KEY = "::Kernel#tap"
      ENTRIES = { KEY => true }.freeze

      class << self
        def watched_keys
          @watched_keys ||= Set.new(ENTRIES.keys)
        end

        def method_keys_for(class_name)
          watched_keys.select { |key| key.start_with?("::#{class_name}#") }
        end

        # Whether `method_name` called on `instance` runs `Kernel#tap`.
        def resolves?(constr, instance, method_name)
          MethodIdentity.keys(constr, instance, method_name, private: false) == [KEY] && !constr.literal_method_registry.blocked?(KEY)
        end

        # The receiver to hand the block: the object as its `initialize` chain
        # leaves it, arrays it starts empty included.
        def receiver_type(constr, node, receiver, receiver_type, method_name)
          instance = fresh_receiver(constr, node, receiver, receiver_type, method_name) or return receiver_type

          built = ObjectStates.state_in(receiver_type)&.ivars || {}
          fresh = ClassMemos.fresh_state(constr, instance) or return receiver_type
          ivars = fresh.ivars.merge(built)
          ivars.empty? ? receiver_type : AST::Types::ObjectState.new(back_type: instance, ivars: ivars)
        end

        # The call answering what its block left the parameter holding.
        def answered(constr, call, node:, receiver_type:)
          return call unless call.is_a?(TypeInference::MethodCall::Typed) && ObjectStates.state_in(receiver_type)

          receiver, method_name = node.children[0].children
          return call unless receiver && fresh_receiver(constr, node, receiver, receiver_type, method_name)

          env = constr.typing.block_exit_of(node: node) or return call
          state = ObjectStates.state_in(env[parameter(node)]) or return call
          declared = ObjectStates.state_in(call.return_type)&.back_type || call.return_type
          return call unless constr.check_relation(sub_type: state, super_type: declared).success?

          call.with_return_type(state)
        end

        # The block's one parameter, `|object|`.
        def parameter(node)
          params = node.children[1].children
          params.first.children[0] if params.size == 1 && %i[arg procarg0].include?(params.first.type) && params.first.children[0].is_a?(Symbol)
        end

        # A jump the block itself takes: a `break` answers its own value, and the
        # others leave or rerun it before the end.
        def jumps?(node)
          return false unless node.is_a?(Parser::AST::Node) && !UnrolledEach::NESTED.include?(node.type)

          Accumulators::JUMPS.include?(node.type) || node.children.any? { |child| jumps?(child) }
        end

        private

        def fresh_receiver(constr, node, receiver, receiver_type, method_name)
          return unless node.type == :block && receiver.type == :send && parameter(node) && !jumps?(node.children[2])

          instance = ObjectStates.state_in(receiver_type)&.back_type || receiver_type
          return unless instance.is_a?(AST::Types::Name::Instance)
          return unless resolves?(constr, instance, method_name)

          built = ObjectStates.recorded_call(constr, receiver)
          return unless built.is_a?(TypeInference::MethodCall::Typed) && ObjectStates.initialize_call?(built)
          return unless ClassMemos.fresh?(constr, instance)

          name = parameter(node)
          held = TypeInference::HeldLocals.of(node, reassigned: TypeInference::ArgumentFacts.reassigned_parameters(node))
          instance if held.held?(name)
        end

      end
    end
  end
end

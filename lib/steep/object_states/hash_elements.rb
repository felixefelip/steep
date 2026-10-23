module Steep
  module ObjectStates
    # The objects a class's hash memo keeps under literal keys
    # (felixefelip/steep#347), followed the way a memo's object is:
    #
    #   def self.instances = @instances ||= {}
    #   def self.instance(locale) = (instances[locale] ||= Rules.new)
    #   instance(:en).singular(/s\z/, "")   # @instances: { en: Rules{@singulars: [[/s\z/, ""]]} }
    #
    # Only where every use of the hash stores into it, asks about its keys, or
    # reads one element whose every use is a call whose effect is known.
    module HashElements
      # What a use of the hash may call without handing an element out.
      KEY_QUERIES = %i[[]= store key? has_key? include? member? size length empty? keys].freeze

      class << self
        # The element `node` reads, as the env holds it: `call` answering it
        # instead of only what holds under any name for it. Where the hash
        # holds nothing under the key yet, a method that stores `Klass.new`
        # there answers that object as it starts out.
        def answered(constr, call, node)
          memo, ivar, key, builds = element_of(constr, node)
          return unless memo && ivar && key

          state = held(constr, ivar, key) || (builds && missing?(constr, ivar, key) && built(constr, call)) or return
          call.with_return_type(state) if keeps?(constr, memo, ivar, state.back_type)
        end

        # A call made on an element leaves the hash holding it as the call's
        # check left it.
        def after(constr, receiver, method_name, arguments, node)
          memo, ivar, key = element_of(constr, receiver)
          return constr unless memo && ivar && key

          state = held(constr, ivar, key) or return constr
          return constr unless keeps?(constr, memo, ivar, state.back_type)

          record = constr.context.type_env[ivar] #: AST::Types::Record
          left = ObjectStates.changed(constr, state, method_name, arguments, node)
          record = AST::Types::Record.new(elements: record.elements.merge(key => left), required_keys: record.required_keys)
          constr.update_type_env do |env|
            env = env.refine_types(instance_variable_types: { ivar => record })
            env.pure_method_calls.key?(receiver) ? env.refine_types(pure_call_types: { receiver => left }) : env.invalidate_pure_node(receiver)
          end
        end

        # The record `stored` leaves where the value is an object `Klass.new`
        # builds, with nothing handed to it, as that object starts out
        # (`ClassMemos.fresh_state`).
        def stored(constr, receiver, record, ivar, arguments)
          key_node, value = arguments
          return unless arguments.size == 2 && fresh_object?(value) && constr.typing.has_type?(key_node) && constr.typing.has_type?(value)

          key = constr.typing.type_of(node: key_node)
          built = constr.typing.type_of(node: value)
          instance = ObjectStates.state_in(built)&.back_type || built
          return unless literal_key?(key) && instance.is_a?(AST::Types::Name::Instance)
          return unless keeps?(constr, receiver.children[1], ivar, instance)

          state = ClassMemos.fresh_state(constr, instance) or return
          [state, AST::Types::Record.new(elements: record.elements.merge(key.value => state), required_keys: record.required_keys | [key.value])]
        end

        private

        # `[memo, ivar, key]` for the element `node` reads: `memo[:key]` on
        # `self`, or a call of a method that hands back what a memo holds under
        # one of its arguments (`Body#hands_back_element`).
        def element_of(constr, node)
          singleton = constr.self_type
          return unless singleton.is_a?(AST::Types::Name::Singleton) && node.type == :send

          receiver, method_name, *arguments = node.children
          if method_name == :[] && receiver && ObjectStates.on_self?(receiver) && arguments.size == 1
            memo = receiver.children[1]
            key_node = arguments[0]
          elsif ObjectStates.on_self?(node)
            memo, index, builds = ObjectStates.resolved_body(constr, singleton, method_name)&.last&.hands_back_element
            key_node = index && arguments[index]
          end
          return unless memo && key_node && constr.typing.has_type?(key_node)

          key = constr.typing.type_of(node: key_node)
          ivar = literal_key?(key) && ClassMemos.tracked_hash_named(constr, singleton, memo) or return
          [memo, ivar, key.value, builds]
        end

        def missing?(constr, ivar, key)
          record = constr.context.type_env[ivar]
          record.is_a?(AST::Types::Nil) || (record.is_a?(AST::Types::Record) && !record.elements.key?(key))
        end

        def built(constr, call)
          instance = ObjectStates.state_in(call.return_type)&.back_type || call.return_type
          ClassMemos.fresh_state(constr, instance) if instance.is_a?(AST::Types::Name::Instance)
        end

        def held(constr, ivar, key)
          record = constr.context.type_env[ivar]
          ObjectStates.state_in(record.elements[key]) if record.is_a?(AST::Types::Record)
        end

        def literal_key?(type)
          type.is_a?(AST::Types::Literal) && type.value.is_a?(::Symbol)
        end

        def fresh_object?(node)
          receiver, method_name, *arguments = node.children
          node.type == :send && method_name == :new && arguments.empty? && receiver&.type == :const
        end

        def keeps?(constr, memo, ivar, instance)
          singleton = constr.self_type #: AST::Types::Name::Singleton
          [memo, ivar].all? do |name|
            Specializations::Receivers.uses_on(constr, name, singleton).all? do |use|
              next false if use.kind == :escape || use.kind == :yielded || !use.element_calls.empty?
              next KEY_QUERIES.include?(use.called) unless TypeInference::ClassMemoAnalyzer::KEY_READS.include?(use.called)

              use.value.all? { |element_use| element_use_kept?(constr, singleton, memo, instance, element_use, true, Set[]) }
            end
          end
        end

        # A call that changes an element is followed (`after`) on `memo[:key]`
        # itself, in a statement of a class body, or on a method that hands it
        # back by key; any other only where it reads.
        def element_use_kept?(constr, singleton, memo, instance, use, followed, visiting)
          if (forwarder = use.forwarded_by)
            return true if visiting.include?(forwarder)

            by_key = ObjectStates.resolved_body(constr, singleton, forwarder)&.last&.hands_back_element&.first == memo
            return Specializations::Receivers.uses_on(constr, forwarder, singleton).all? do |forwarded|
              element_use_kept?(constr, singleton, memo, instance, forwarded, followed && by_key, visiting | [forwarder])
            end
          end
          return false if use.kind == :escape || use.kind == :yielded || !use.element_calls.empty?

          effect = ObjectStates.method_effect(constr, instance, use.called) or return false
          effect.reads_only || (followed && use.kind == :statement)
        end
      end
    end
  end
end

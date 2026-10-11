module Steep
  module ObjectStates
    # The objects a class keeps in an ivar of its own through a memo
    # (`TypeInference::ConstructorBindingAnalyzer::Body#memo`), followed through
    # the class body that sets them up (felixefelip/steep#205, stage 3), and the
    # arrays such an object starts empty and only pushes onto.
    module ClassMemos
      class << self
        # A memo called on `self` hands back the object its ivar holds, as the
        # state the env knows it in (`TypeInference::ClassMemoAnalyzer`); or,
        # where the ivar is still `nil`, the one it builds.
        def remembered(constr, call, node)
          return [nil, constr] unless ObjectStates.on_self?(node)

          ivar, instance = tracked_memo(constr, call)
          current = ivar && constr.context.type_env[ivar]
          state = ObjectStates.state_in(current) || (current.is_a?(AST::Types::Nil) && fresh_state(constr, instance)) or return [nil, constr]
          [call.with_return_type(state), constr.update_type_env { |env| env.refine_types(instance_variable_types: { ivar => state }) }]
        end

        # What `Klass.new` holds when its `initialize` chain is done: each array
        # it starts empty and only pushes onto afterwards.
        def fresh_state(constr, instance)
          chain = ObjectStates.initialize_chain(constr, instance) or return
          empties = chain.flat_map { |_, body| body ? body.empties.to_a : [] }
          ivars = empties.select { |ivar| collection_confined?(constr, instance, ivar) }.to_h { |ivar| [ivar, AST::Types::Tuple.new(types: [])] }
          AST::Types::ObjectState.new(back_type: instance, ivars: ivars)
        end

        # The memos' ivars start `nil` in the one class body that runs code,
        # where no `inherited` of the project's has run on the class first.
        def entered_class(constr)
          singleton = constr.self_type
          return constr unless singleton.is_a?(AST::Types::Name::Singleton)

          registry = constr.constructor_bindings
          return constr unless registry.class_bodies(singleton.name.to_s) <= 1

          definition = constr.checker.factory.definition_builder.build_singleton(singleton.name)
          ancestors = definition.ancestors.ancestors.map { |ancestor| ancestor.name.to_s }
          return constr if ancestors.any? { |name| registry.defines?(name, :inherited, singleton: true) }

          memos = ancestors.flat_map { |name| registry.singleton_method_bodies(name).values.flatten.filter_map { |body| body&.memo&.first } }
          return constr if memos.empty?

          constr.update_type_env { |env| env.refine_types(instance_variable_types: memos.to_h { |ivar| [ivar, AST::Builtin.nil_type] }) }
        rescue RBS::BaseError
          constr
        end

        # A call made on what a memo answered moves the object its ivar holds.
        # Where nothing was known yet, it is still that one object, so what the
        # call binds is known from here.
        def remembered_after(constr, receiver, receiver_type, method_name, arguments, node)
          memo_call = ObjectStates.recorded_call(constr, receiver)
          ivar, instance = tracked_memo(constr, memo_call) if memo_call
          return constr unless ivar && instance

          state = ObjectStates.state_in(receiver_type) || AST::Types::ObjectState.new(back_type: instance, ivars: {})
          left = ObjectStates.changed(constr, state, method_name, arguments, node)
          constr.update_type_env do |env|
            env = env.refine_types(instance_variable_types: { ivar => left })
            # The memo call is pure, and a second one is answered from the cache.
            env.pure_method_calls.key?(receiver) ? env.refine_types(pure_call_types: { receiver => left }) : env.invalidate_pure_node(receiver)
          end
        end

        # `[ivar, instance]` for a call on `self` to a class's memo
        # (`Body#memo`) whose object no code the project holds can reach but
        # through a call on it: `initialize` does not hand it on, no other method
        # may write the ivar, every use of the memo and of its ivar is the
        # receiver of a call whose effect is known, and only a statement of a
        # class body, made on `self`, may call more than a reader on it.
        def tracked_memo(constr, call)
          singleton = constr.self_type
          return unless call.is_a?(TypeInference::MethodCall::Typed) && singleton.is_a?(AST::Types::Name::Singleton)

          owner, body = ObjectStates.resolved_body(constr, singleton, call.method_name)
          ivar, classes = body&.memo
          instance = constr.typing.nominal_of(node: call.node) || call.return_type
          instance = ObjectStates.state_in(instance)&.back_type || instance
          return unless ivar && instance.is_a?(AST::Types::Name::Instance) && classes.include?(instance.name.to_s.delete_prefix("::"))
          return unless fresh?(constr, instance) && written_only_by?(constr, singleton, ivar, owner, call.method_name)
          return unless [call.method_name, ivar].all? { |used| confined?(constr, instance, used) }

          [ivar, instance]
        end

        # `Klass.new` hands back an object nothing else holds.
        def fresh?(constr, instance)
          chain = ObjectStates.initialize_chain(constr, instance) or return false
          chain.none? { |_, body| body && ObjectStates.exposes_self?(constr, instance, body, [:initialize]) }
        end

        def written_only_by?(constr, singleton, ivar, owner, method_name)
          definition = constr.checker.factory.definition_builder.build_singleton(singleton.name)
          definition.ancestors.ancestors.none? do |ancestor|
            constr.postconditions.may_write?(ancestor.name.to_s, ivar, except: ancestor.name == owner ? method_name : nil)
          end
        rescue RBS::BaseError
          false
        end

        def confined?(constr, instance, name)
          constr.constructor_bindings.uses_of(name).all? do |use|
            next false if use.kind == :escape

            effect = ObjectStates.method_effect(constr, instance, use.called) or next false
            use.kind == :statement || effect.reads_only
          end
        end

        # What a use of an array this vouches for may call on it.
        def collection_read?(constr, method_name)
          return true if CollectionReaders::WHOLE.include?(method_name)

          keys = IterationIntrinsics::ENTRIES.keys.select { |key| key.end_with?("##{method_name}") }
          !keys.empty? && keys.none? { |key| constr.literal_method_registry.blocked?(key) }
        end

        # Whether a method a block hands an element to may be one the project
        # wrote: a core one it replaced, or one of its own of that name.
        def element_read_replaced?(constr, method_name)
          registry = constr.literal_method_registry
          registry.name_blocked?(method_name) || constr.constructor_bindings.defines_any?([method_name]) ||
            ElementReads.keys_for(method_name).any? { |key| registry.blocked?(key) }
        end

        # Nothing the project holds can change the array `instance` keeps in
        # `ivar`, nor one of its elements: only an `initialize` sets it, to `[]`,
        # its own methods only push onto it or hand it out through a reader, and
        # every use of it and of those readers only reads it — a block handed
        # its elements included (`CollectionReaders::ITERATIONS`).
        def collection_confined?(constr, instance, ivar)
          registry = constr.constructor_bindings
          readers = [] #: Array[Symbol]
          definition = constr.checker.factory.definition_builder.build_instance(instance.name)
          definition.ancestors.ancestors.each do |ancestor|
            registry.method_bodies(ancestor.name.to_s).each do |name, bodies|
              bodies.each do |body|
                return false unless body
                next readers << name if body.returns == ivar
                return false if body.handed.include?(ivar) || (body.writes - body.empties).include?(ivar)
              end
            end
          end

          uses = [ivar, *readers].flat_map { |name| registry.uses_of(name) }
          uses.all? { |use| use.kind != :escape && collection_read?(constr, use.called) } &&
            uses.flat_map { |use| use.element_calls.to_a }.none? { |name| element_read_replaced?(constr, name) }
        rescue RBS::BaseError
          false
        end
      end
    end
  end
end

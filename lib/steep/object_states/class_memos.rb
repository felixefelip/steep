module Steep
  module ObjectStates
    # The objects a class keeps in an ivar of its own through a memo
    # (`TypeInference::ConstructorBindingAnalyzer::Body#memo`), followed through
    # the class body that sets them up (felixefelip/steep#205, stage 3), and the
    # arrays such an object starts empty and only pushes onto.
    module ClassMemos
      EMPTY_HASH = AST::Types::Record.new(elements: {}, required_keys: Set[])

      class << self
        # A memo called on `self` hands back the object its ivar holds, as the
        # state the env knows it in (`TypeInference::ClassMemoAnalyzer`); or,
        # where the ivar is still `nil`, the one it builds.
        def remembered(constr, call, node)
          return [nil, constr] unless ObjectStates.on_self?(node)
          hash_ivar = tracked_hash(constr, call)
          return remembered_hash(constr, call, hash_ivar) if hash_ivar

          ivar, instance, wrappers = tracked_memo(constr, call)
          current = ivar && constr.context.type_env[ivar]
          state = ObjectStates.state_in(current) || (current.is_a?(AST::Types::Nil) && built(constr, call, node, ivar, instance, wrappers)) or return [nil, constr]
          [call.with_return_type(state), constr.update_type_env { |env| env.refine_types(instance_variable_types: { ivar => state }) }]
        end

        # A memo of a hash answers what the env knows it holds, or, where the
        # ivar is still `nil`, the empty hash it stores there. A method keyed on
        # one class reads what that class's body, and its subclasses' bodies,
        # left it holding (`stored_by_class_bodies`).
        def remembered_hash(constr, call, ivar)
          current = constr.context.type_env[ivar]
          state = current.is_a?(AST::Types::Nil) ? EMPTY_HASH : current
          state = stored_by_class_bodies(constr, call, ivar) || state unless state.is_a?(AST::Types::Record)
          return [nil, constr] unless state.is_a?(AST::Types::Record)

          [call.with_return_type(state), constr.update_type_env { |env| env.refine_types(instance_variable_types: { ivar => state }) }]
        end

        # What the hash holds in a method body run on one class, where every
        # store into it is made by a class body on its own class
        # (`ConstructorBindingRegistry#class_body_storing`) and no storing
        # method is one the runtime may call by itself: under each
        # key, what the bodies of the class and of each subclass left there. A
        # key some of them never store is optional, since a subclass's hash is
        # its own.
        def stored_by_class_bodies(constr, call, ivar)
          return unless constr.method_context

          singleton = Specializations.exact_self(constr) or return
          storing = constr.constructor_bindings.class_body_storing(call.method_name, ivar) or return
          return if overrides_class_method?(constr, storing)

          descendants = constr.checker.factory.descendant_index.descendants(singleton.name, limit: ReflectionIntrinsics::MAX_DESCENDANTS) or return
          records = [singleton.name, *descendants].map do |name|
            return unless constr.constructor_bindings.class_bodies(name.to_s) <= 1

            left = constr.specializations.class_exit(name, ivar)
            left = EMPTY_HASH if left.nil? || left.is_a?(AST::Types::Nil)
            return unless left.is_a?(AST::Types::Record)

            left
          end
          merged_records(records)
        end

        # Every method the runtime calls on a class object by itself (a hook,
        # an operator, `const_missing`, ...) is one `Class` already has.
        def overrides_class_method?(constr, names)
          class_methods = constr.checker.factory.definition_builder.build_instance(AST::Builtin::Class.module_name).methods
          names.any? { |name| class_methods.key?(name) }
        end

        def merged_records(records)
          keys = records.flat_map { |record| record.elements.keys }.uniq
          elements = keys.to_h { |key| [key, AST::Types::Union.build(types: records.filter_map { |record| record.elements[key] })] }
          required = keys.select { |key| records.all? { |record| record.required_keys.include?(key) } }
          AST::Types::Record.new(elements: elements, required_keys: required.to_set)
        end

        # What each hash memo of the class holds where its body ends, for a
        # method run after it.
        def record_hash_exits(exit)
          singleton = exit.self_type
          return unless singleton.is_a?(AST::Types::Name::Singleton)

          ivars = ObjectStates.class_side_bodies(exit, singleton).filter_map { |_, _, body| body&.memoized_hash }.uniq
          return if ivars.empty?

          env = exit.context.type_env
          exit.typing.add_class_exit(singleton.name, ivars.to_h { |ivar| [ivar, env[ivar]] })
        end

        # The ivar of a call on `self` to a memo of an empty hash
        # (`Body#memoized_hash`) only the memo writes, and whose hash, and the
        # memo answering it, the project only stores into or reads from
        # (`HashMutation.confined?`).
        def tracked_hash(constr, call)
          singleton = constr.self_type
          return unless call.is_a?(TypeInference::MethodCall::Typed) && singleton.is_a?(AST::Types::Name::Singleton)

          owner, body = ObjectStates.resolved_body(constr, singleton, call.method_name)
          ivar = body&.memoized_hash or return
          return unless written_only_by?(constr, singleton, ivar, owner, call.method_name)
          uses = [call.method_name, ivar].flat_map { |name| Specializations::Receivers.uses_on(constr, name, singleton) }
          return unless HashMutation.confined?(constr.literal_method_registry, uses)

          ivar
        end

        # What a memo still `nil` builds: the object `Klass.new` does, or, where
        # calls are made on it first, what the memo's own check, entered with
        # the ivar `nil`, left the ivar holding.
        def built(constr, call, node, ivar, instance, wrappers)
          return fresh_state(constr, instance) if wrappers.empty?

          key = Specializations.body_key(constr, call, node) or return
          arguments = Specializations.call_site_arguments(constr, node, call) or return
          ObjectStates.state_in(ObjectStates.recorded_exit(constr, key, arguments)&.ivars&.[](ivar))
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

          memos = ObjectStates.class_side_bodies(constr, singleton).filter_map { |_, _, body| body&.memoizes }
          return constr if memos.empty?

          constr.update_type_env { |env| env.refine_types(instance_variable_types: memos.to_h { |ivar| [ivar, AST::Builtin.nil_type] }) }
        rescue RBS::BaseError
          constr
        end

        # The memos of `self`'s class that hold no object state and whose value
        # the env knows: still `nil`, or a class or module, which nothing but
        # the memo writes and the memo writes only while it is `nil`.
        def memo_values(constr)
          singleton = constr.self_type
          return {} unless singleton.is_a?(AST::Types::Name::Singleton)

          env = constr.context.type_env
          value_memos(constr, singleton).filter_map do |ivar, owner, method_name|
            type = env[ivar]
            next unless type.is_a?(AST::Types::Nil) || type.is_a?(AST::Types::Name::Singleton) || type.is_a?(AST::Types::Record)
            next if type == env.declared_instance_variable_types[ivar]

            [ivar, type] if written_only_through?(constr, singleton, ivar, owner, method_name)
          end.to_h
        end

        # Whether every method that may write `ivar` does so only by calling
        # the memo: none but the memo writes it itself, and every other one's
        # body is readable.
        def written_only_through?(constr, singleton, ivar, owner, method_name)
          bodies = ObjectStates.class_side_bodies(constr, singleton).group_by { |name, method, _| [name, method] }
          constr.checker.factory.definition_builder.build_singleton(singleton.name).ancestors.ancestors.all? do |ancestor|
            constr.postconditions.may_write_methods(ancestor.name.to_s, ivar).all? do |writer|
              next true if ancestor.name == owner && writer == method_name

              found = bodies[[ancestor.name, writer]] || []
              found.size == 1 && found.first[2] && !found.first[2].writes.include?(ivar)
            end
          end
        rescue RBS::BaseError
          false
        end

        def value_memo?(constr, singleton, ivar)
          singleton.is_a?(AST::Types::Name::Singleton) && value_memos(constr, singleton).any? { |memo, _, _| memo == ivar }
        end

        # `[ivar, owner, method name]` for each `def self.m = @ivar ||= value`
        # on the class's ancestors. One whose `Klass.new` they follow holds no
        # object state only while it is `nil`.
        def value_memos(constr, singleton)
          ObjectStates.class_side_bodies(constr, singleton).filter_map do |owner, method_name, body|
            [body.memoizes, owner, method_name] if body&.memoizes
          end
        end

        # `@x ||= value` where the env knows more of `@x` than its declaration:
        # known `nil`, the value is assigned; known set, it is not evaluated,
        # and the arm left is recorded for what reads the body's flow.
        def or_assigned(constr, node, hint)
          asgn, rhs = node.children
          env = constr.context.type_env
          current = env[asgn.children[0]]
          declared = env.declared_instance_variable_types[asgn.children[0]]
          arm = or_arm(current, declared) if node.type == :or_asgn
          constr.typing.add_arm(node, arm)

          type, after = constr.synthesize(rhs, hint: declared || hint)
          return [current, constr] if arm == :else

          after.ivasgn(asgn, type)
        end

        def or_arm(current, declared)
          return nil if current.nil? || current == declared

          case current
          when AST::Types::Nil then :then
          when AST::Types::Name::Singleton, AST::Types::ObjectState then :else
          end
        end

        # In a class body, a call may reach a memo still `nil`: it holds what the
        # call's own check left it, or what its declaration says. So does a memo
        # whose object a method the call runs (`reached`) yields to a block.
        def after_class_call(constr, exit, reached)
          return constr if constr.method_context

          moved = memo_values(constr).select { |_, type| type.is_a?(AST::Types::Nil) || type.is_a?(AST::Types::Record) }
          moved = moved.merge(yielded_memos(constr, reached)) if reached
          return constr if moved.empty?

          exit ||= {}
          constr.update_type_env do |env|
            env.refine_types(instance_variable_types: moved.to_h { |ivar, _| [ivar, exit.fetch(ivar) { ObjectStates.declared_ivar(constr, ivar) }] })
          end
        end

        # `Klass.new` whose `initialize` chain only binds or stores what it is
        # handed, making no call and no `yield`: it reaches no class's memo,
        # whatever block or callable it was given.
        def builds_only?(constr, call)
          return false unless call.is_a?(TypeInference::MethodCall::Typed) && ObjectStates.initialize_call?(call)

          instance = call.return_type
          instance = ObjectStates.state_in(instance)&.back_type || instance
          return false unless instance.is_a?(AST::Types::Name::Instance)

          chain = ObjectStates.initialize_chain(constr, instance) or return false
          chain.all? { |_, body| body.nil? || !body.calls }
        end

        def yielded_memos(constr, reached)
          singleton = constr.self_type
          return {} unless singleton.is_a?(AST::Types::Name::Singleton)

          env = constr.context.type_env
          value_memos(constr, singleton).filter_map do |ivar, _, method_name|
            yielders = constr.constructor_bindings.uses_of(method_name).filter_map { |use| use.called if use.kind == :yielded }
            [ivar, env[ivar]] if ObjectStates.state_in(env[ivar]) && reached.intersect?(yielders)
          end.to_h
        end

        # A call made on what a memo answered moves the object its ivar holds.
        # Where nothing was known yet, it is still that one object, so what the
        # call binds is known from here.
        def remembered_after(constr, receiver, receiver_type, method_name, arguments, node)
          memo_call = ObjectStates.recorded_call(constr, receiver)
          ivar, instance = tracked_memo(constr, memo_call) if memo_call
          return constr unless ivar && instance

          state = ObjectStates.state_in(receiver_type) || AST::Types::ObjectState.new(back_type: instance, ivars: {})
          remembered_as(constr, receiver, ivar, ObjectStates.changed(constr, state, method_name, arguments, node))
        end

        # The memo `receiver` called left holding `left`.
        def remembered_as(constr, receiver, ivar, left)
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
          ivar, classes, wrappers = body&.memo
          instance = constr.typing.nominal_of(node: call.node) || call.return_type
          instance = ObjectStates.state_in(instance)&.back_type || instance
          return unless ivar && instance.is_a?(AST::Types::Name::Instance) && classes.include?(instance.name.to_s.delete_prefix("::"))
          return unless fresh?(constr, instance) && written_only_by?(constr, singleton, ivar, owner, call.method_name)
          return unless [call.method_name, ivar].all? { |used| confined?(constr, singleton, instance, used) }
          return unless wrappers.all? { |name| Tap.resolves?(constr, instance, name) }

          [ivar, instance, wrappers]
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

        def confined?(constr, singleton, instance, name)
          Specializations::Receivers.uses_on(constr, name, singleton).all? do |use|
            next false if use.kind == :escape
            next constr.constructor_bindings.replayed_everywhere?(use.called) if use.kind == :yielded

            effect = ObjectStates.method_effect(constr, instance, use.called) or next false
            use.kind == :statement || effect.reads_only
          end
        end

        # Whether each use only reads the array, and a block handed its
        # elements only reads them.
        def reading_uses?(constr, uses)
          uses.all? { |use| use.kind != :escape && collection_read?(constr, use.called) && reads_elements?(constr, use.element_calls) }
        end

        def reads_elements?(constr, calls)
          calls.none? { |name| element_read_replaced?(constr, name) }
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

          reading_uses?(constr, [ivar, *readers].flat_map { |name| Specializations::Receivers.uses_on(constr, name, instance) })
        rescue RBS::BaseError
          false
        end
      end
    end
  end
end

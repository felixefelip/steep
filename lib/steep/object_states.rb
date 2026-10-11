module Steep
  # Where an `AST::Types::ObjectState` comes from and what it answers
  # (felixefelip/steep#205, stage 1).
  #
  #   reflection = Reflection.new(:posts)   # ::Reflection{@name: :posts}
  #   reflection.name                       # :posts
  #
  # Both are read off the call the checker already typed, against the method it
  # resolved to, and only ever narrow it: the declared return is the bound.
  #
  # An ivar no method but `initialize` writes holds under any name. One another
  # method writes holds only while a single local owns the object
  # (`TypeInference::HeldLocals`), and each call made through it moves it.
  module ObjectStates
    # `reads_only`: the method only answers an ivar (`attr_reader`, `def x = @x`).
    Effect = Struct.new(:bindings, :writes, :reads_only, keyword_init: true)

    class << self
      # The locals handed on are settled here, ahead of the callee's
      # postconditions, so a fact one states about them (`unconditional.params`)
      # is not dropped by the settling.
      def answered(constr, call, node:, receiver_type:, arguments:)
        memo, constr = ClassMemos.remembered(constr, call, node)
        call = read(constr, memo || built(constr, call, node: node, arguments: arguments), receiver_type: receiver_type, arguments: arguments)
        [call, handed_on(constr, arguments)]
      end

      # What a body checked under its receiver's contents leaves the receiver
      # holding, of the ivars it was entered with. Only where the body ends
      # where it falls off: a `return` leaves from elsewhere.
      def record_exit(constr, def_node, pair)
        arguments = constr.specialization_arguments(def_node) or return
        return if arguments.self_ivars.empty? || returns_early?(pair_body(def_node))

        env = pair.context.type_env
        exit = arguments.self_ivars.keys.to_h { |ivar| [ivar, env[ivar]] }.select { |_, type| state_value?(type) }
        root = constr.typing
        root = root.parent while root.parent
        root.add_exit_ivars(def_node, exit)
      end

      def returns_early?(body)
        LocalReach.each_node(body) { |node| return true if node.type == :return }
        false
      end

      def pair_body(def_node)
        def_node.type == :defs ? def_node.children[3] : def_node.children[2]
      end

      # A value a state may hold: one nothing can change, or the contents of an
      # array, kept only where nothing else reaches it (`collection_confined?`).
      def state_value?(type)
        fixed?(type) || type.is_a?(AST::Types::Tuple) || type.is_a?(AST::Types::RegexpLiteral)
      end

      # A method runs whenever it is called, not where it is written: nothing
      # the class body around it cached about a call answers one there.
      def entered_method(env)
        env.pure_method_calls.empty? && env.class_states.empty? ? env : env.update(pure_method_calls: {}, class_states: {})
      end

      # The ivars of `self` whose object the env knows the state of, for a body
      # this one calls on `self` to start from.
      def self_ivars(constr)
        constr.context.type_env.instance_variable_types.select { |_, type| state_in(type) }
      end

      # A `.new` call whose `initialize` binds an ivar from one of the values
      # it was passed, answering the object with that ivar known. Any other
      # call that answers a state answers the ivars that hold under any name,
      # since only `.new` hands back an object nothing else has.
      def built(constr, call, node:, arguments:)
        unless initialize_call?(call)
          returned = settled(constr, call.return_type)
          return returned == call.return_type ? call : call.with_return_type(returned)
        end
        return call unless arguments.all? { |argument| plain_argument?(argument) }

        instance = call.return_type
        return call unless instance.is_a?(AST::Types::Name::Instance)

        chain = initialize_chain(constr, instance) or return call
        held = held_value?(constr, node) && chain.none? { |_, body| body && exposes_self?(constr, instance, body, [:initialize]) }
        rewritten = chain.flat_map { |_, body| body ? callee_writes(constr, instance, body, [:initialize]).to_a : [] }
        bindings = compose(chain).select do |ivar, _|
          held ? declared?(constr, instance, ivar) && !rewritten.include?(ivar) : never_rewritten?(constr, instance, ivar)
        end
        ivars = bound_values(constr, bindings, arguments)
        return call if ivars.empty?

        call.with_return_type(AST::Types::ObjectState.new(back_type: instance, ivars: ivars))
      end

      # What the locals a call touched hold once it returns: the receiver as
      # the method left it, met with the markers its postcondition refined it
      # by; and each local handed on as an argument with only the ivars that
      # hold under any name, since the callee may change or keep it
      # (`TypeInference::HeldLocals` keeps such a local out of anything it
      # cannot follow). `answered` settled those already on a typed call without
      # a block; this covers a block, an untyped receiver and the correlated
      # paths.
      def after_call(constr, node:, method_name:, receiver:, receiver_type:, arguments:)
        if receiver&.type == :lvar && holds_state?(receiver_type)
          name = receiver.children[0]
          constr = refine_local(constr, name, left(constr, receiver_type, constr.context.type_env[name], method_name, arguments, node))
        end
        constr = ClassMemos.remembered_after(constr, receiver, receiver_type, method_name, arguments, node) if receiver && on_self?(receiver)
        constr = self_moved(constr, node) if receiver.nil? || receiver.type == :self
        handed_on(constr, arguments)
      end

      # A call on `self` from a body checked under its receiver's contents
      # leaves them as that call's own check left them, and where nothing says
      # so, keeps only what no call can change.
      def self_moved(constr, node)
        def_node = constr.method_context&.node or return constr
        entered = constr.specialization_arguments(def_node)&.self_ivars
        return constr if entered.nil? || entered.empty?

        env = constr.context.type_env
        exit = exit_of(constr, node) || entered.keys.to_h { |ivar| [ivar, env[ivar]] }.reject { |_, type| !type || !fixed?(type) || state_in(type) }
        constr.update_type_env do |current|
          entered.each_key.reduce(current) do |result, ivar|
            result.refine_types(instance_variable_types: { ivar => exit.fetch(ivar) { declared_ivar(constr, ivar) } })
          end
        end
      end

      def declared_ivar(constr, ivar)
        constr.context.type_env.declared_instance_variable_types[ivar] || AST::Builtin.any_type
      end

      # What the body a call reached left its receiver holding, where it was
      # checked under the contents this call's receiver holds.
      def exit_of(constr, node)
        call = recorded_call(constr, node)
        key = call.is_a?(TypeInference::MethodCall::Typed) && Specializations.method_key(call.method_decls) or return
        arguments = Specializations::Arguments.recorded(node, constr.typing) or return
        constr.specializations.exit_ivars(key, arguments.key) if arguments.stateful?
      end

      # The type an ivar takes after an assignment, or nil to leave it at its
      # declaration: the value assigned where the declaration is a union (the
      # branch it selects, felixefelip/steep#16) or where the env held a
      # refined view — a state's contents are no longer what it holds.
      def assigned_ivar(current, declared_type, rhs_type, passed:)
        refined = declared_type && current != declared_type
        return rhs_type if passed && (declared_type.is_a?(AST::Types::Union) || refined)

        declared_type if refined
      end

      def on_self?(node)
        %i[send csend].include?(node.type) && (node.children[0].nil? || node.children[0].type == :self)
      end

      def recorded_call(constr, node)
        constr.typing.call_of(node: node)
      rescue Typing::UnknownNodeError
        nil
      end

      def handed_on(constr, arguments)
        handed_locals(arguments).reduce(constr) do |current, name|
          type = current.context.type_env[name] or next current
          refine_local(current, name, settled(current, type))
        end
      end

      # `type` with every state reduced to the ivars no method but
      # `initialize` writes.
      def settled(constr, type)
        case type
        when AST::Types::ObjectState
          ivars = type.ivars.select { |ivar, value| fixed?(value) && never_rewritten?(constr, type.back_type, ivar) }
          ivars.empty? ? type.back_type : AST::Types::ObjectState.new(back_type: type.back_type, ivars: ivars)
        when AST::Types::Union, AST::Types::Intersection
          members = type.types.map { |member| settled(constr, member) }
          members == type.types ? type : type.class.build(types: members)
        else
          type
        end
      end

      # A reader called on an object whose ivar is known, answering what the
      # object holds. `call` unchanged for any other call.
      def read(constr, call, receiver_type:, arguments:)
        state = state_in(receiver_type)
        return call unless state && arguments.empty?

        ivar = constr.attr_method_backing_ivar(call.method_decls) ||
               bound_reader_ivar(constr, state, call)
        value = ivar && state.ivar_type(ivar) or return call
        # The checker cannot bind a block's parameters to the elements of `[]`.
        return call if value.is_a?(AST::Types::Tuple) && value.types.empty?
        return call unless constr.check_relation(sub_type: value, super_type: call.return_type).success?

        call.with_return_type(value)
      end

      # The state `type` is, alone or met with the markers a postcondition
      # refined it by (`Reflection{@name: :articles} & Reflection::AfterRename`).
      def state_in(type)
        case type
        when AST::Types::ObjectState then type
        when AST::Types::Intersection then type.types.grep(AST::Types::ObjectState).first
        end
      end

      # The `initialize` methods `Klass.new` runs, from the one it calls to the
      # last one a `super` reaches (felixefelip/steep#230), as
      # `[owner, initializer]` pairs. Which one runs, and which one a `super`
      # reaches, is the RBS definition's answer, so an inherited `initialize`
      # and one from an included module are found the way any other method
      # is. Nil when the chain cannot be read whole:
      #
      # - a Ruby `initialize` the RBS does not place there would run first;
      # - one the project defines twice, or that could not be read;
      # - a `super` that may not run, or reaches a body with no source
      #   (`BasicObject#initialize`, which writes nothing, ends the chain).
      def initialize_chain(constr, instance)
        registry = constr.constructor_bindings
        definition = constr.checker.factory.definition_builder.build_instance(instance.name)
        ancestors = definition.ancestors.ancestors.map(&:name)
        method = definition.methods[:initialize] or return nil

        chain = [] #: Array[[RBS::TypeName, TypeInference::ConstructorBindingAnalyzer::Body?]]
        passed = 0
        loop do
          owner = method.implemented_in or return nil
          index = ancestors.index(owner) or return nil
          return nil if index < passed
          skipped = ancestors[passed...index] || []
          return nil if skipped.any? { |name| !registry.initializers_for(name.to_s).empty? }

          initializers = registry.initializers_for(owner.to_s)
          if initializers.empty?
            return nil unless owner == RBS::BuiltinNames::BasicObject.name
            chain << [owner, nil]
            return chain
          end
          initializer = initializers.first
          return nil unless initializers.size == 1 && initializer

          chain << [owner, initializer]
          passed = index + 1
          case initializer.super_args
          when nil then return chain
          when :opaque then return nil
          end
          method = method.super_method or return nil
        end
      rescue RBS::BaseError
        nil
      end

      # Whether `self` may reach anything but a call made on it, here or in a
      # method this calls on `self`. One with no body to read may: `itself`,
      # `tap` and `define_singleton_method` hand it on.
      def exposes_self?(constr, instance, body, visiting)
        return true if body.exposes_self

        body.self_sends.any? do |name|
          next false if visiting.include?(name)

          _, callee = resolved_body(constr, instance, name)
          callee.nil? || exposes_self?(constr, instance, callee, [*visiting, name])
        end
      end

      # What `method_name` does to an instance of `instance`: the ivars it may
      # write, from `may_write` (closed over the methods it calls on `self`),
      # and the ones its body binds to an argument and nothing it calls on
      # `self` may write after. Nil when the body cannot be read, calls
      # `super`, or may hand `self` on; and until `steep check` has written a
      # sidecar, since nothing then says what any method writes.
      def method_effect(constr, instance, method_name)
        return nil if constr.postconditions.empty?

        owner, body = resolved_body(constr, instance, method_name)
        return nil if owner.nil? || body.nil? || body.super_args || exposes_self?(constr, instance, body, [method_name])

        rewritten = callee_writes(constr, instance, body, [method_name])
        writes = may_write(constr, owner, method_name) | rewritten
        reads_only = !body.returns.nil? && body.self_sends.empty? && writes.empty?
        Effect.new(bindings: body.bindings.reject { |ivar, _| rewritten.include?(ivar) }, writes: writes, reads_only: reads_only)
      end

      # `[owner, body]` for the `method_name` an instance of `type` runs, or
      # the class object `type` names when it is a singleton. Which one runs is
      # the RBS definition's answer, as for `initialize`
      # (felixefelip/steep#230). Nil when a Ruby method of that name the RBS
      # does not place would run first.
      def resolved_body(constr, type, method_name)
        registry = constr.constructor_bindings
        singleton = type.is_a?(AST::Types::Name::Singleton)
        builder = constr.checker.factory.definition_builder
        definition = singleton ? builder.build_singleton(type.name) : builder.build_instance(type.name)
        owner = definition.methods[method_name]&.implemented_in or return nil
        ancestors = definition.ancestors.ancestors.map(&:name)
        index = ancestors.index(owner) or return nil
        return nil if ancestors.take(index).any? { |name| registry.defines?(name.to_s, method_name, singleton: singleton) }

        body = singleton ? registry.singleton_body_of(owner.to_s, method_name) : registry.body_of(owner.to_s, method_name)
        body ? [owner, body] : nil
      rescue RBS::BaseError
        nil
      end

      # A method whose body this cannot read leaves only what holds under any
      # name.
      # What a call leaves the object it was made on holding: what its own
      # check under the object's contents left (`exit_of`); otherwise what its
      # effect binds, and only the ivars no call can change — an array crosses a
      # call only through a check that followed it.
      def changed(constr, state, method_name, arguments, node)
        if (exit = exit_of(constr, node))
          kept = exit.select { |ivar, value| !value.is_a?(AST::Types::Tuple) || ClassMemos.collection_confined?(constr, state.back_type, ivar) }
          return kept.empty? ? state.back_type : AST::Types::ObjectState.new(back_type: state.back_type, ivars: kept)
        end

        effect = method_effect(constr, state.back_type, method_name) or return settled(constr, state)
        plain = arguments.all? { |argument| plain_argument?(argument) }
        rebound = plain ? bound_values(constr, effect.bindings, arguments) : {} #: Hash[Symbol, AST::Types::t]
        ivars = state.ivars.reject { |ivar, value| effect.writes.include?(ivar) || (!fixed?(value) && !effect.reads_only) }
        ivars.merge!(rebound)
        ivars.empty? ? state.back_type : AST::Types::ObjectState.new(back_type: state.back_type, ivars: ivars)
      end

      # A value nothing can change afterwards, or one of several. A String
      # literal names a value that can (felixefelip/steep#216), and so does an
      # array.
      def fixed?(type)
        case type
        when AST::Types::Literal then !type.value.is_a?(::String)
        when AST::Types::Nil, AST::Types::ObjectState then true
        when AST::Types::Union then type.types.all? { |member| fixed?(member) }
        else false
        end
      end

      # One argument, one position: a splat, keywords or a block pass move what
      # lands where.
      def plain_argument?(argument)
        !%i[splat kwargs block_pass forwarded_args forwarded_restarg].include?(argument.type)
      end

      private

      def held_value?(constr, node)
        constr.method_context&.held_locals&.held_value?(node) || false
      end

      def bound_values(constr, bindings, arguments)
        bindings.filter_map do |ivar, index|
          argument = arguments[index] or next
          next unless constr.typing.has_type?(argument)

          type = settled(constr, constr.literal_operand_type(argument, constr.typing.type_of(node: argument)))
          [ivar, type] if fixed?(type) || frozen_literal?(constr, argument, type)
        end.to_h
      end

      # A string written in a source under `# frozen_string_literal: true`,
      # which no name can change. Only as written: an interpolation builds a
      # string that is not frozen.
      def frozen_literal?(constr, node, type)
        return false unless node.type == :str && type.is_a?(AST::Types::Literal) && type.value.is_a?(::String)

        frozen_source?(constr.source)
      end

      def frozen_source?(source)
        @frozen_sources ||= {}.compare_by_identity
        @frozen_sources.fetch(source) do
          comments = Prism.parse(source.buffer.content).magic_comments
          @frozen_sources[source] = comments.any? { |comment| comment.key == "frozen_string_literal" && comment.value == "true" }
        end
      end

      # Only a state alone keeps the markers the postcondition left in
      # `current`: a union member cannot tell which of them is its own.
      def left(constr, receiver_type, current, method_name, arguments, node)
        if receiver_type.is_a?(AST::Types::Union)
          return AST::Types::Union.build(types: receiver_type.types.map { |member| left(constr, member, nil, method_name, arguments, node) })
        end
        state = state_in(receiver_type) or return receiver_type

        changed = changed(constr, state, method_name, arguments, node)
        markers = markers_in(current, state)
        markers.empty? ? changed : AST::Types::Intersection.build(types: [changed, *markers])
      end

      def holds_state?(type)
        state_in(type) || (type.is_a?(AST::Types::Union) && type.types.any? { |member| state_in(member) })
      end

      def markers_in(current, state)
        return [] unless current.is_a?(AST::Types::Intersection)

        current.types.reject { |member| member.is_a?(AST::Types::ObjectState) || member == state.back_type }
      end

      def refine_local(constr, name, type)
        return constr if constr.context.type_env[name] == type

        constr.update_type_env do |env|
          env.invalidate_pure_node(::Parser::AST::Node.new(:lvar, [name])).refine_types(local_variable_types: { name => type })
        end
      end

      def handed_locals(arguments)
        LocalReach.argument_values(arguments).filter_map { |value| value.children[0] if value.type == :lvar }
      end

      # What the methods `body` calls on `self` may write, each resolved on
      # `instance`. `may_write` alone is closed in the class that defines the
      # caller, so it misses a subclass's override.
      def callee_writes(constr, instance, body, visiting)
        body.self_sends.each_with_object(Set[]) do |name, writes|
          next if visiting.include?(name)

          owner, callee = resolved_body(constr, instance, name)
          next unless owner

          writes.merge(may_write(constr, owner, name))
          writes.merge(callee_writes(constr, instance, callee, [*visiting, name])) if callee
        end
      end

      def may_write(constr, owner, method_name)
        constr.postconditions.lookup_instance(owner, method_name)&.may_write_ivars || Set[]
      end

      # `Klass.new` resolved to the class's own `initialize`: a `def self.new`
      # answers whatever it likes.
      def initialize_call?(call)
        !call.method_decls.empty? &&
          call.method_decls.all? { |decl| decl.method_def&.member.respond_to?(:name) && decl.method_def.member.name == :initialize }
      end

      # `@ivar => call-site position` for the object `chain` leaves behind,
      # composed from the last `initialize` up. A `super` hands an ancestor's
      # binding on through the argument it passed at that position; an ivar
      # one level writes and another level also writes is bound by neither,
      # since which write lands last is a question of order this does not ask.
      def compose(chain)
        bindings = {} #: Hash[Symbol, Integer]
        writes = Set[] #: Set[Symbol]
        chain.reverse_each do |_, initializer|
          next unless initializer

          super_args = initializer.super_args
          inherited = {} #: Hash[Symbol, Integer]
          if super_args.is_a?(Array)
            bindings.each do |ivar, position|
              source = super_args[position]
              inherited[ivar] = source if source && !initializer.writes.include?(ivar)
            end
          end
          own = initializer.bindings.reject { |ivar, _| writes.include?(ivar) }
          bindings = inherited.merge(own)
          writes |= initializer.writes
        end
        bindings
      end

      # Nothing but an `initialize` writes `ivar`: no other method of the class
      # or of any ancestor has it in `may_write`. An `initialize` runs on the
      # object only while it is built, and the ones that do are the chain
      # `compose` already read; the others never run on it at all. That answer comes
      # from the postconditions sidecar, so with none loaded yet nothing is
      # fixed; and `may_write` only records ivars the RBS declares, so an
      # undeclared one is not either.
      #
      # Writes `may_write` does not see yet: felixefelip/steep#219 (a scoped
      # reopen, `define_method`, a constant-receiver `class_eval`) and #220
      # (writes from outside the class).
      def never_rewritten?(constr, instance, ivar)
        postconditions = constr.postconditions
        return false if postconditions.empty? || !declared?(constr, instance, ivar)

        definition = constr.checker.factory.definition_builder.build_instance(instance.name)
        definition.ancestors.ancestors.none? do |ancestor|
          postconditions.may_write?(ancestor.name.to_s, ivar, except: :initialize)
        end
      rescue RBS::BaseError
        false
      end

      def declared?(constr, instance, ivar)
        constr.checker.factory.definition_builder.build_instance(instance.name).instance_variables.key?(ivar)
      rescue RBS::BaseError
        false
      end

      # A reader written as `def name = @name` rather than `attr_reader`, in
      # the class or in the ancestor that defines it (felixefelip/steep#230).
      def bound_reader_ivar(constr, receiver_type, call)
        method_name = call.method_name or return nil
        resolved_body(constr, receiver_type.back_type, method_name)&.last&.returns
      end
    end
  end
end

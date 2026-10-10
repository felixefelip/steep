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
  # An ivar no method but `initialize` writes is fixed for good, and holds
  # under any name. One another method writes holds only while a single local
  # owns the object (`TypeInference::HeldLocals`), and moves with each call
  # made through it (stage 2):
  #
  #   reflection = Reflection.new(:posts)   # ::Reflection{@name: :posts}
  #   reflection.rename(:articles)          # ::Reflection{@name: :articles}
  #   define_stored(reflection)             # handed on; ::Reflection here after
  module ObjectStates
    # What running a method does to the object it runs on: the ivars it may
    # write, and the ones it leaves holding an argument, by call-site position.
    Effect = Struct.new(:bindings, :writes, keyword_init: true)

    class << self
      # `call` as `built` and `read` answer it, and `constr` with the locals it
      # was handed settled ahead of what the callee's postconditions say about
      # them.
      def answered(constr, call, node:, receiver_type:, arguments:)
        call = read(constr, built(constr, call, node: node, arguments: arguments), receiver_type: receiver_type, arguments: arguments)
        [call, handed_on(constr, arguments)]
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
        held = held_value?(constr, node) && chain.all? { |_, body| body.nil? || effect(constr, instance, body, [:initialize]) }
        bindings = compose(chain).select { |ivar, _| held || never_rewritten?(constr, instance, ivar) }
        ivars = bound_values(constr, bindings, arguments)
        return call if ivars.empty?

        call.with_return_type(AST::Types::ObjectState.new(back_type: instance, ivars: ivars))
      end

      # What the locals a call touched hold once it returns: the receiver as
      # the method left it, met with the markers its postcondition refined it
      # by; and each local handed on as an argument with only the ivars that
      # hold under any name, since the callee may change or keep it
      # (`TypeInference::HeldLocals` keeps such a local out of anything it
      # cannot follow).
      def after_call(constr, method_name:, receiver:, receiver_type:, arguments:)
        if receiver&.type == :lvar && holds_state?(receiver_type)
          name = receiver.children[0]
          constr = refine_local(constr, name, left(constr, receiver_type, constr.context.type_env[name], method_name, arguments))
        end
        handed_on(constr, arguments)
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
          ivars = type.ivars.select { |ivar, _| never_rewritten?(constr, type.back_type, ivar) }
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
        return call unless constr.check_relation(sub_type: value, super_type: call.return_type).success?

        call.with_return_type(value)
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
          [ivar, type] if fixed?(type)
        end.to_h
      end

      # `state` once `method_name` ran on it with `arguments`: an ivar the
      # method does not write keeps its value, one it binds takes the
      # argument's, and any other it writes is no longer known. A method whose
      # body this cannot read leaves only what holds under any name.
      def changed(constr, state, method_name, arguments)
        effect = method_effect(constr, state.back_type, method_name, [method_name]) or return settled(constr, state)
        plain = arguments.all? { |argument| plain_argument?(argument) }
        rebound = plain ? bound_values(constr, effect.bindings, arguments) : {} #: Hash[Symbol, AST::Types::t]
        ivars = state.ivars.reject { |ivar, _| effect.writes.include?(ivar) }
        ivars.merge!(rebound.slice(*state.ivars.keys))
        ivars.empty? ? state.back_type : AST::Types::ObjectState.new(back_type: state.back_type, ivars: ivars)
      end

      # `receiver_type` once the call ran on it. A union is each of the
      # objects it may be, and only a state alone keeps the markers the
      # postcondition left in `current`.
      def left(constr, receiver_type, current, method_name, arguments)
        if receiver_type.is_a?(AST::Types::Union)
          return AST::Types::Union.build(types: receiver_type.types.map { |member| left(constr, member, nil, method_name, arguments) })
        end
        state = state_in(receiver_type) or return receiver_type

        changed = changed(constr, state, method_name, arguments)
        markers = markers_in(current, state)
        markers.empty? ? changed : AST::Types::Intersection.build(types: [changed, *markers])
      end

      def holds_state?(type)
        state_in(type) || (type.is_a?(AST::Types::Union) && type.types.any? { |member| state_in(member) })
      end

      # The state `type` is, alone or met with the markers a postcondition
      # refined it by (`Reflection{@name: :articles} & Reflection::AfterRename`).
      def state_in(type)
        case type
        when AST::Types::ObjectState then type
        when AST::Types::Intersection then type.types.grep(AST::Types::ObjectState).first
        end
      end

      # The markers the local is met with once the call returned: the ones
      # the callee's postcondition put in place of the class, or the ones it
      # already had.
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
        values = arguments.flat_map do |argument|
          argument.type == :kwargs ? argument.children.filter_map { |pair| pair.children[1] if pair.type == :pair } : [argument]
        end
        values.filter_map { |value| value.children[0] if value.type == :lvar }
      end

      # What `method_name` does to an instance of `instance`, read off the
      # body the RBS definition says runs, and off every method it calls on
      # `self`. Nil when that body may hand `self` on, calls `super` or a
      # method with no body to read, or calls back into itself.
      def method_effect(constr, instance, method_name, visiting)
        body = resolved_body(constr, instance, method_name) or return nil
        return nil if body.super_args

        effect(constr, instance, body, visiting)
      end

      def effect(constr, instance, body, visiting)
        return nil if body.exposes_self

        callee_writes = Set[] #: Set[Symbol]
        body.self_sends.each do |name|
          return nil if visiting.include?(name)

          callee = method_effect(constr, instance, name, [*visiting, name]) or return nil
          callee_writes.merge(callee.writes)
        end
        Effect.new(bindings: body.bindings.reject { |ivar, _| callee_writes.include?(ivar) }, writes: body.writes | callee_writes)
      end

      # The body of the `method_name` an instance of `instance` runs. Which
      # one runs is the RBS definition's answer, as for `initialize`
      # (felixefelip/steep#230). Nil when a Ruby method of that name the RBS
      # does not place would run first.
      def resolved_body(constr, instance, method_name)
        registry = constr.constructor_bindings
        definition = constr.checker.factory.definition_builder.build_instance(instance.name)
        owner = definition.methods[method_name]&.implemented_in or return nil
        ancestors = definition.ancestors.ancestors.map(&:name)
        index = ancestors.index(owner) or return nil
        return nil if ancestors.take(index).any? { |name| registry.defines?(name.to_s, method_name) }

        registry.body_of(owner.to_s, method_name)
      rescue RBS::BaseError
        nil
      end

      # `Klass.new` resolved to the class's own `initialize`: a `def self.new`
      # answers whatever it likes.
      def initialize_call?(call)
        !call.method_decls.empty? &&
          call.method_decls.all? { |decl| decl.method_def&.member.respond_to?(:name) && decl.method_def.member.name == :initialize }
      end

      # One argument, one position: a splat, keywords or a block pass move what
      # lands where.
      def plain_argument?(argument)
        !%i[splat kwargs block_pass forwarded_args forwarded_restarg].include?(argument.type)
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
        return false if postconditions.empty?

        definition = constr.checker.factory.definition_builder.build_instance(instance.name)
        return false unless definition.instance_variables.key?(ivar)

        definition.ancestors.ancestors.none? do |ancestor|
          postconditions.may_write?(ancestor.name.to_s, ivar, except: :initialize)
        end
      rescue RBS::BaseError
        false
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

      # A reader written as `def name = @name` rather than `attr_reader`, in
      # the class or in the ancestor that defines it (felixefelip/steep#230).
      def bound_reader_ivar(constr, receiver_type, call)
        method_name = call.method_name or return nil
        resolved_body(constr, receiver_type.back_type, method_name)&.returns
      end
    end
  end
end

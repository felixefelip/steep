module Steep
  module ObjectStates
    # A block written at a call, checked where it runs: at the `yield` of the
    # method it is handed, inside that method's check under the call
    # (felixefelip/steep#263).
    #
    #   def self.inflections = yield(rules)
    #   inflections { |inflect| inflect.singular(/s\z/, "") }   # writes the memo's object
    #
    # Only a block that reads nothing of the scope it is written in: its one
    # parameter, what it assigns itself, literals and absolute constants. And
    # only one yielded a memo's object (`ClassMemos#tracked_memo`), which
    # nothing else holds, so what the block leaves its parameter holding is
    # what the memo holds.
    module Yields
      # `x += 1` reads `x` first, so it names a local of the block only where
      # the block made it.
      OPERATOR_WRITES = %i[op_asgn or_asgn and_asgn].freeze

      FOREIGN = %i[self ivar ivasgn cvar cvasgn gvar gvasgn super zsuper yield block_pass def defs class module sclass].freeze

      # Core methods that read the calling frame and nothing of `self`.
      ENTRIES = { "::Kernel#block_given?" => true }.freeze

      class << self
        def watched_keys
          @watched_keys ||= Set.new(ENTRIES.keys)
        end

        def method_keys_for(class_name)
          watched_keys.select { |key| key.start_with?("::#{class_name}#") }
        end

        # The `ENTRIES` key a call on `self` without a receiver runs, unless the
        # project replaced it.
        def frame_reader(constr, node)
          return unless node.type == :send && node.children[0].nil?

          keys = MethodIdentity.keys(constr, constr.self_type, node.children[1], private: true)
          keys.first if keys.size == 1 && ENTRIES.key?(keys.first) && !constr.literal_method_registry.blocked?(keys.first)
        end

        def replayable?(block)
          closed_params(block)&.size == 1
        end

        # The parameters of a block that computes the same wherever it runs:
        # plain ones, and a body that reads nothing else (`own?`).
        def closed_params(block)
          return unless block.type == :block

          closed = (@closed ||= ObjectSpace::WeakMap.new)
          return closed[block] if closed.key?(block)

          closed[block] = closed_params_of(block)
        end

        def closed_params_of(block)
          names = block.children[1].children.map { |param| %i[arg procarg0].include?(param.type) && param.children[0].is_a?(Symbol) ? param.children[0] : (return nil) }
          body = block.children[2] or return names

          locals = Set.new(names)
          targets = Set[].compare_by_identity #: Set[Parser::AST::Node]
          LocalReach.each_node(body) do |node|
            targets << node.children[0] if OPERATOR_WRITES.include?(node.type)
            locals << node.children[0] if node.type == :lvasgn && !targets.include?(node)
          end
          names if !Tap.jumps?(body) && own?(body, locals)
        end

        # A closed block's name, from its normalized source: what it does.
        def digest(block)
          Digest::SHA256.hexdigest(block.loc.begin.join(block.loc.end).source.gsub(/\s+/, " "))[0, 16]
        end

        # What a `yield` answers, and the env it leaves, in a body checked
        # under a call that wrote a closed block: the block's body checked
        # with its parameters holding what is yielded, once, where that is
        # what the block may return.
        def at_yield(constr, node, declared)
          left, value = replayed(constr, node)
          block = (def_node = constr.method_context&.node) && constr.specialization_arguments(def_node)&.block
          { type: value ? fitted(constr, value, declared) : replayed_value(constr, block, node.children, declared), constr: left }
        end

        # `proc.call(…)` on a proc made from a closed block, a `yield` to it.
        def called(constr, call, node)
          return call unless call.is_a?(TypeInference::MethodCall::Typed) && node.type == :send && node.children[1] == :call
          return call unless (receiver = node.children[0]) && constr.typing.has_type?(receiver)

          proc = constr.typing.type_of(node: receiver)
          return call unless proc.is_a?(AST::Types::ClosedProc)

          type = replayed_value(constr, proc.source, node.children.drop(2), call.return_type)
          type.equal?(call.return_type) ? call : call.with_return_type(type)
        end

        def replayed_value(constr, block, values, declared)
          names = block && closed_params(block) or return declared
          return declared unless values.size == names.size && values.all? { |value| !%i[splat block_pass].include?(value.type) && constr.typing.has_type?(value) }

          body = block.children[2] or return AST::Builtin.nil_type
          inner = constr.with_new_typing(constr.typing.new_child).update_type_env do |env|
            names.zip(values).reduce(env) { |left, (name, value)| left.assign_local_variable(name, constr.typing.type_of(node: value), nil) }
          end
          fitted(constr, inner.synthesize(body).type, declared)
        end

        def fitted(constr, type, declared)
          constr.check_relation(sub_type: type, super_type: declared).success? ? type : declared
        end

        def own?(node, locals)
          return true unless node.is_a?(Parser::AST::Node)
          return false if FOREIGN.include?(node.type)
          return locals.include?(node.children[0]) if node.type == :lvar
          return false if OPERATOR_WRITES.include?(node.type) && node.children[0].type == :lvasgn && !locals.include?(node.children[0].children[0])
          return absolute?(node) if node.type == :const
          return false if node.type == :send && node.children[0].nil?

          node.children.all? { |child| own?(child, locals) }
        end

        def absolute?(node)
          node = node.children[0] while node&.type == :const
          node.nil? ? false : node.type == :cbase
        end

        # The env a `yield` of a memo's object leaves, in a body checked under a
        # call that wrote a block for it: the block's body checked there, its
        # parameter holding the object, and the memo left holding what the
        # block left the parameter holding, or its declaration where that is no
        # one state. The block's own locals do not outlive it, and neither does
        # its typing: its nodes are typed where they are written. With it, what
        # the body answered there, where it was checked.
        def replayed(constr, node)
          def_node = constr.method_context&.node or return [constr, nil]
          block = constr.specialization_arguments(def_node)&.block or return [constr, nil]
          return [constr, nil] unless node.children.size == 1 && replayable?(block)

          value = node.children[0]
          ivar, = ClassMemos.tracked_memo(constr, ObjectStates.recorded_call(constr, value)) if ObjectStates.on_self?(value)
          element = HashElements.followed(constr, value) unless ivar
          on_class = HashElements.on_class(constr, value) unless ivar || element
          memo_on_class = ClassMemos.on_class(constr, value) unless ivar || element || on_class
          state = (ivar && ObjectStates.state_in(constr.typing.type_of(node: value))) || element || on_class&.last || memo_on_class&.last
          return [unfollowed(constr, value), nil] unless state

          name = Tap.parameter(block)
          inner = constr.with_new_typing(constr.typing.new_child).update_type_env { |env| env.assign_local_variable(name, state, nil) }
          pair = inner.synthesize(block.children[2]) if block.children[2]
          inner = pair.constr if pair
          left = ObjectStates.state_in(inner.context.type_env[name])
          constr = constr.update_type_env { |env| env.update(instance_variable_types: inner.context.type_env.instance_variable_types, class_states: inner.context.type_env.class_states) }
          [left_by_replay(constr, value, state, left, ivar: ivar, element: element, on_class: on_class, memo_on_class: memo_on_class), pair ? pair.type : AST::Builtin.nil_type]
        end

        def left_by_replay(constr, value, state, left, ivar:, element:, on_class:, memo_on_class:)
          return HashElements.left_by(constr, value, left || state.back_type) if element
          return HashElements.left_on_class(constr, on_class, left || state.back_type) if on_class
          return ClassMemos.left_on_class(constr, memo_on_class, left) if memo_on_class

          ClassMemos.remembered_as(constr, value, ivar, left || ObjectStates.declared_ivar(constr, ivar))
        end

        # A block yielded a class's object by its name, which the replay does
        # not follow, may change it: what the env knew of that class, `self`
        # included, is known no longer.
        def unfollowed(constr, value)
          receiver = value.children[0] if value.type == :send
          return constr unless receiver&.type == :const && constr.typing.has_type?(receiver)

          singleton = constr.typing.type_of(node: receiver)
          return constr unless singleton.is_a?(AST::Types::Name::Singleton)
          return constr.update_type_env { |env| env.update(class_states: env.class_states.except(singleton.name)) } unless singleton == constr.self_type

          env = constr.context.type_env
          known = env.instance_variable_types.keys.select { |ivar| ObjectStates.state_in(env[ivar]) || env[ivar].is_a?(AST::Types::Record) || env[ivar].is_a?(AST::Types::Nil) }
          constr.update_type_env { |current| current.refine_types(instance_variable_types: known.to_h { |ivar| [ivar, ObjectStates.declared_ivar(constr, ivar)] }) }
        end

        # `block_given?` in a body checked under a call, which says whether it
        # wrote one.
        def block_given(constr, call, node)
          return call unless frame_reader(constr, node) == "::Kernel#block_given?"

          def_node = constr.method_context&.node or return call
          arguments = constr.specialization_arguments(def_node) or return call
          call.with_return_type(AST::Types::Literal.new(value: !!(arguments.block || arguments.block_return)))
        end
      end
    end
  end
end

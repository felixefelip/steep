module Steep
  module ObjectStates
    # A block written at a call, checked where it runs: at the `yield` of the
    # method it is handed, inside that method's check under the call
    # (felixefelip/steep#263).
    #
    #   def self.inflections = yield(rules)
    #   inflections { |inflect| inflect.singular(/s\z/, "") }   # writes the memo's object
    #
    # Only a block that reads nothing of the scope it is written in is checked
    # there, since that scope is not where it runs: its one parameter, what it
    # assigns itself, literals and absolute constants. And only one yielded a
    # memo's object (`ClassMemos#tracked_memo`), which nothing else holds, so
    # what the block leaves its parameter holding is what the memo holds.
    module Yields
      FOREIGN = %i[self ivar ivasgn cvar cvasgn gvar gvasgn super zsuper yield block_pass def defs class module sclass].freeze

      class << self
        def replayable?(block)
          name = block.type == :block && Tap.parameter(block) or return false
          body = block.children[2] or return true

          locals = Set[name]
          LocalReach.each_node(body) { |node| locals << node.children[0] if node.type == :lvasgn }
          !Tap.jumps?(body) && own?(body, locals)
        end

        def own?(node, locals)
          return true unless node.is_a?(Parser::AST::Node)
          return false if FOREIGN.include?(node.type)
          return locals.include?(node.children[0]) if node.type == :lvar
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
        # its typing: its nodes are typed where they are written.
        def replayed(constr, node)
          def_node = constr.method_context&.node or return constr
          block = constr.specialization_arguments(def_node)&.block or return constr
          return constr unless node.children.size == 1 && replayable?(block)

          value = node.children[0]
          ivar, = ClassMemos.tracked_memo(constr, ObjectStates.recorded_call(constr, value)) if ObjectStates.on_self?(value)
          state = ivar && ObjectStates.state_in(constr.typing.type_of(node: value)) or return constr

          name = Tap.parameter(block)
          inner = constr.with_new_typing(constr.typing.new_child).update_type_env { |env| env.assign_local_variable(name, state, nil) }
          inner = inner.synthesize(block.children[2]).constr if block.children[2]
          left = ObjectStates.state_in(inner.context.type_env[name]) || ObjectStates.declared_ivar(constr, ivar)
          ClassMemos.remembered_as(constr.update_type_env { |env| env.update(instance_variable_types: inner.context.type_env.instance_variable_types, class_states: inner.context.type_env.class_states) }, value, ivar, left)
        end

        # `Kernel#block_given?`, which reads the frame and nothing of `self`.
        def block_given?(constr, node)
          node.type == :send && node.children[0].nil? && node.children[1] == :block_given? &&
            MethodIdentity.keys(constr, constr.self_type, :block_given?, private: true) == ["::Kernel#block_given?"]
        end

        # `block_given?` in a body checked under a call, which says whether it
        # wrote one.
        def block_given(constr, call, node)
          return call unless block_given?(constr, node)

          def_node = constr.method_context&.node or return call
          arguments = constr.specialization_arguments(def_node) or return call
          call.with_return_type(arguments.block ? AST::Types::Literal.new(value: true) : AST::Types::Literal.new(value: false))
        end
      end
    end
  end
end

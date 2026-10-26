module Steep
  module ObjectStates
    # An object whose state another one keeps in an ivar
    # (felixefelip/steep#343): `Rules{@uncountables: Uncountables{@regex_array: […]}}`.
    # A call on the holder changes the object held as its check says, and a
    # reader that hands the object out leaves the holder with what holds under
    # any name for it, unless the reader's value goes straight to a call that
    # only reads it.
    module Nested
      class << self
        # The object a reader answers, as the state its holder keeps it in, where
        # the reader's value goes nowhere but the receiver of `method_name`, a
        # method that only reads it: `rules.uncountables.uncountable?(word)`.
        # The holder keeps it as it was, where `changed` let it go.
        def read_through(constr, receiver, receiver_type, method_name)
          return [receiver_type, constr] unless receiver.type == :send && receiver.children.size == 2 && (holder_node = receiver.children[0])

          reader = ObjectStates.recorded_call(constr, receiver)
          return [receiver_type, constr] unless reader.is_a?(TypeInference::MethodCall::Typed) && constr.typing.has_type?(holder_node)

          holder = ObjectStates.state_in(constr.typing.type_of(node: holder_node)) or return [receiver_type, constr]
          ivar = ObjectStates.reader_ivar(constr, holder, reader) or return [receiver_type, constr]
          held = ObjectStates.state_in(holder.ivar_type(ivar)) or return [receiver_type, constr]
          return [receiver_type, constr] unless held.back_type == (ObjectStates.state_in(receiver_type)&.back_type || receiver_type)
          return [receiver_type, constr] unless inspects?(constr, held.back_type, method_name, [])

          [held, refine_holder(constr, holder_node, holder)]
        end

        # `constr` with the object `node` reads known as `state`, where `node`
        # is a name the env follows: a local, an ivar of `self`, or a class's
        # memo.
        def refine_holder(constr, node, state)
          return HeldIvar.refine_variable(constr, node, state) if HeldIvar.variable(constr, node)

          memo_call = ObjectStates.recorded_call(constr, node) or return constr
          ivar, = ClassMemos.tracked_memo(constr, memo_call)
          ivar ? ClassMemos.remembered_as(constr, node, ivar, state) : constr
        end

        # `state` once a reader has answered the object it keeps in `ivar`, which
        # may be named and changed elsewhere from there: only what holds under any
        # name for it.
        def handed_out(constr, state, ivar)
          held = ObjectStates.state_in(state.ivar_type(ivar)) or return state

          kept = ObjectStates.state_in(ObjectStates.settled(constr, held))
          AST::Types::ObjectState.new(back_type: state.back_type, ivars: kept ? state.ivars.merge(ivar => kept) : state.ivars.except(ivar))
        end

        # Whether each use of `ivar` only reads what it holds: an array, through
        # a call `ClassMemos.reading_uses?` vouches for; a hash, through one
        # `HashMutation` does; an object of the project's, through a call that
        # `inspects?` it.
        def reads_ivar?(constr, instance, ivar, uses, visiting)
          return true if ClassMemos.reading_uses?(constr, uses)

          held = declared_ivar_type(constr, instance, ivar)
          return false unless held.is_a?(AST::Types::Name::Instance)
          return HashMutation.reads_only?(constr, uses) if held.name == AST::Builtin::Hash.module_name

          uses.all? { |use| use.kind == :receiver && use.called && inspects?(constr, held, use.called, visiting) }
        end

        # Whether `method_name` only reads an instance of `instance` and hands
        # out nothing it holds: a reader answers its ivar, which its caller may
        # then change.
        def inspects?(constr, instance, method_name, visiting)
          return false if visiting.include?([instance, method_name])

          effect = ObjectStates.method_effect(constr, instance, method_name, visiting) or return false
          effect.reads_only && !effect.reader
        end

        def declared_ivar_type(constr, instance, ivar)
          variable = constr.checker.factory.definition_builder.build_instance(instance.name).instance_variables[ivar] or return
          constr.checker.factory.type(variable.type)
        rescue RBS::BaseError
          nil
        end
      end
    end
  end
end

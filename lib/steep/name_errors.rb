module Steep
  # Whether a call certainly raises `NameError` (`:raises`), certainly does not
  # (`:resolves`), or may do either (nil), for a `rescue NameError` around it
  # to run or not.
  #
  # A reflection says so itself: one that found what it looks for raised
  # nothing, one on a name nothing declares raised (`ReflectionIntrinsics`).
  # A call to a method says so through the body it was checked under for this
  # call's arguments, when that body is one such call and nothing else:
  #
  #   def constantize(w) = Object.const_get(w)
  #
  #   def safe_constantize(w)
  #     constantize(w)          # "Comment": :resolves; "Post::Comment": :raises
  #   rescue NameError
  #     nil
  #   end
  #
  # A call resolves only where its operands are read, never computed:
  # `foo.bar.public_instance_method(:x)` can raise from `foo.bar`, since a
  # `NoMethodError` is a `NameError`. One that raises does so whatever they do.
  module NameErrors
    module_function

    def of_call(constr, node, type)
      return unless node.type == :send

      call = constr.typing.call_of(node: node)
      outcome = constr.raising_reflection?(node) ? :raises : (ReflectionIntrinsics.resolved?(call, type) && :resolves) || through_body(constr, call, node)
      outcome unless outcome == :resolves && !read_operands?(node)
    rescue Typing::UnknownNodeError
      nil
    end

    def read_operands?(node)
      receiver, _, *arguments = node.children
      [receiver, *arguments].all? { |operand| operand.nil? || TypeConstruction::READ_OPERANDS.include?(operand.type) }
    end

    # What the body this call reached left as its outcome, checked under this
    # call's arguments.
    def through_body(constr, call, node)
      return unless call.is_a?(TypeInference::MethodCall::Typed) && Specializations.method_key(call.method_decls)

      arguments = Specializations::Arguments.recorded(node, constr.typing) or return
      key = Specializations.body_key(constr, call, node) or return
      ObjectStates.recorded_exit(constr, key, arguments)&.name_error
    end

    # A body checked under arguments that hold no state leaves no exit but
    # this one.
    def record(constr, def_node, pair)
      name_error = of_body(constr, ObjectStates.pair_body(def_node), pair.type)
      root = constr.typing
      root = root.parent while root.parent
      root.add_exit_ivars(def_node, ObjectStates::Exit.new(ivars: {}, classes: {}, params: {}, name_error: name_error))
    end

    # The outcome of a body that is one call and nothing else.
    def of_body(constr, body, type)
      body && of_call(constr, body, type)
    end
  end
end

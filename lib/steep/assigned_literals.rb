module Steep
  # A local holding a literal that a loop or a block assigns again holds,
  # from the body's second pass on, whatever the assignment wrote:
  #
  #     def sum(init = 0)          # specialized: `init` is `0`
  #       value = init
  #       while more? do value += 1 end
  #       value                    # not `0`
  #     end
  #
  # So it enters the body widened (`Specializations.widen_literals`), as
  # `StringMutation` widens a String a call may change, and the literal is
  # kept as `unwidened` for `UnrolledEach` to run the passes from where it
  # knows each one.
  module AssignedLiterals
    module_function

    # `constr` with what a loop or a block body may change widened: a String
    # a call in it may change (`StringMutation`) and a literal it assigns.
    def widen_changed_in(constr, node, shadowed: Set[])
      widen_in(StringMutation.widen_mutated_in(constr, node, shadowed: shadowed), node, shadowed: shadowed)
    end

    def widen_in(constr, node, shadowed: Set[])
      unwidened = {} #: Hash[Symbol, AST::Types::t]
      assigned_names(node, shadowed, Set[]).each do |name|
        type = constr.context.type_env[name] or next
        unwidened[name] = type unless Specializations.widen_literals(type) == type
      end
      return constr if unwidened.empty?

      constr.typing.add_unwidened(node, unwidened)
      constr.update_type_env do |env|
        env.refine_types(local_variable_types: unwidened.transform_values { |type| Specializations.widen_literals(type) })
      end
    end

    # The outer locals `node` assigns, but those a block parameter rebinds.
    def assigned_names(node, shadowed, names)
      return names unless node.is_a?(Parser::AST::Node)

      case node.type
      when *LocalReach::SCOPES
        return names
      when *Accumulators::LAMBDA_BODIES
        send_node, params, body = node.children
        assigned_names(send_node, shadowed, names)
        return assigned_names(body, shadowed + StringMutation.block_parameter_names(params), names)
      when :lvasgn
        names << node.children[0] unless shadowed.include?(node.children[0])
      end

      node.children.each { |child| assigned_names(child, shadowed, names) }
      names
    end
  end
end

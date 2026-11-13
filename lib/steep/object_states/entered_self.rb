module Steep
  module ObjectStates
    # What `self` holds in a body checked for its receiver's contents
    # (`Specializations::Arguments#self_ivars`), for a reader called on it to
    # answer, as an `ObjectState` would for any other receiver.
    module EnteredSelf
      def self.state(constr, receiver_type, call)
        self_type = constr.self_type
        return unless receiver_type.is_a?(AST::Types::Self) && self_type.is_a?(AST::Types::Name::Instance)

        ivars = ObjectStates.call_ivars(constr, call)
        AST::Types::ObjectState.new(back_type: self_type, ivars: ivars) unless ivars.empty?
      end

      # An ivar the body was entered with holds the value assigned as
      # written: a hash as the record it writes, a literal as itself.
      def self.assigned(pair, ivar, value)
        constr = pair.constr
        def_node = constr.method_context&.node
        return pair unless def_node && constr.specialization_arguments(def_node)&.self_ivars&.key?(ivar)

        operand = Specializations::Arguments.written_record(value, constr.typing, nil) || handed_value(constr, def_node, value) ||
                  Specializations::Arguments.written_array(value, constr.typing) || constr.literal_operand_type(value, pair.type)
        return pair unless ObjectStates.state_value?(operand)

        pair.with(constr: constr.update_type_env { |env| env.refine_types(instance_variable_types: { ivar => operand }) })
      end

      # `@a, @b = x, y` leaves each ivar holding what `@a = x` would.
      def self.assigned_together(constr, node)
        targets = node.children[0].children
        values = node.children[1]
        return constr unless values.type == :array && values.children.size == targets.size && (targets + values.children).none? { _1.type == :splat }

        targets.zip(values.children).reduce(constr) do |current, (target, value)|
          next current unless target.type == :ivasgn

          assigned(TypeConstruction::Pair.new(type: current.typing.type_of(node: value), constr: current), target.children[0], value).constr
        end
      end

      # What a local held where a statement of the method's own straight line
      # assigned it to the ivar, where nothing names it afterwards: the ivar
      # holds that array, and nothing is left to change it through the local.
      def self.handed_value(constr, def_node, value)
        return unless value.type == :lvar

        elements = constr.source.accumulators.at_args[value] or return
        body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
        statements = body&.type == :begin ? body.children : [body]
        return unless statements.any? { |statement| statement&.type == :ivasgn && statement.children[1].equal?(value) }
        return if LocalReach.mentions_after?(body, value)

        types = Accumulators::Contents.types(constr, elements) or return
        AST::Types::Tuple.new(types: types)
      end
    end
  end
end

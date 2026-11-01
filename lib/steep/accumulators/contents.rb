module Steep
  module Accumulators
    # What the checker makes of the entries `Accumulators` leaves: the types
    # each one stands for, asked of the construction checking the body.
    module Contents
      module_function

      # The types of an accumulator's contents, in order, or nil where any one
      # of them is not a literal. A `Loop` stands for one run of its pushes per
      # pass, and the passes are the ones `record_iterations` checked; a loop it
      # did not expand has no count, so the contents have none either. A
      # `Branch` stands for the pushes of the arm the check left reachable — per
      # pass, inside a loop — and one whose condition stayed open has no
      # contents to give.
      def types(constr, elements, pass = nil, types = [])
        elements.each { |element| add(constr, element, pass, types) or return nil }
        types
      end

      # `types` with what one entry stands for appended, or nil.
      def add(constr, element, pass, types)
        case element
        when Loop
          passes = constr.typing.iterations_of(node: element.block) or return nil
          passes.all? { |each_pass| types(constr, element.values, each_pass, types) } && types
        when Arrived then concat(types, constr.arrived_types(element))
        when Built then concat(types, constr.built_types(element))
        when Spliced then concat(types, spliced(constr, element, pass ? pass[element] : spliced_type(constr, element.node)))
        when Reshaped then concat(types, types(constr, element.elements, pass)&.then { |before| reshaped(constr, element, before) })
        when Mapped then concat(types, mapped(constr, element))
        when Branch then branch(constr, element, pass, types)
        else
          type = pass ? pass[element] : element_type(constr, element)
          types << type if value?(type)
        end
      end

      def branch(constr, element, pass, types)
        case pass ? pass[element.node] : constr.typing.arm_of(node: element.node)
        when :then then types(constr, element.then_values, pass, types)
        when :else then types(constr, element.else_values, pass, types)
        end
      end

      def concat(types, more)
        more && types.concat(more)
      end

      # The type of one pushed element, read from the NODE.
      #
      # A literal written as a statement's argument widens to its class by the
      # time anything asks the typing — and a push from an earlier statement may
      # not be in this typing at all, since each check builds its own. The
      # syntax is the same either way, and it is exact.
      #
      # Only a literal or `nil` counts: an array holding anything else has no
      # contents to state, which is the right answer for `parts << some_value`.
      def element_type(constr, node)
        type = operand_type(constr, node)
        type if value?(type)
      end

      def value?(type)
        type.is_a?(AST::Types::Literal) || type.is_a?(AST::Types::Nil)
      end

      # The array a `Spliced` node evaluates to, read as a pushed value is.
      def spliced_type(constr, node)
        operand_type(constr, node)
      end

      def operand_type(constr, node)
        typing = constr.typing
        inferred = typing.recorded_type_of(node: node) || AST::Builtin.any_type
        constr.literal_operand_type(node, inferred)
      end

      # The elements a `Spliced` copies in, or nil where they are not all
      # values the fold reads.
      def spliced(constr, element, tuple)
        return nil if constr.literal_method_registry.blocked?(element.key)
        return nil unless tuple.is_a?(AST::Types::Tuple) && tuple.types.all? { |type| LiteralIntrinsics.fold_value?(type) }

        tuple.types
      end

      def mapped(constr, element)
        tuple = constr.typing.vouched_of(node: element.block)
        tuple.types if tuple.is_a?(AST::Types::Tuple) && tuple.types.all? { |type| LiteralIntrinsics.fold_value?(type) }
      end

      def reshaped(constr, element, before)
        registry = constr.literal_method_registry
        return nil if registry.blocked?(element.key)

        after = LiteralIntrinsics.fold_key(
          key: element.fold_key, receiver_type: AST::Types::Tuple.new(types: before), argument_types: [],
          override_registry: registry
        )
        after.types if after.is_a?(AST::Types::Tuple)
      end
    end
  end
end

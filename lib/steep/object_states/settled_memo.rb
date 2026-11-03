module Steep
  module ObjectStates
    # `@x ||= value` as the whole body of an instance method, where no other
    # method writes `@x` and `value` reads only what stays as it was once the
    # object is built (`KeyedMemo.settled?`). Unset, the memo stores `value`;
    # set, it holds what an earlier call stored, the same value. Either way it
    # answers `value`:
    #
    #   def parents = @parents ||= parent ? [parent].concat(parent.parents) : []
    module SettledMemo
      def self.answers?(constr, node)
        instance = constr.self_type
        method_name = constr.method_context&.name
        asgn, value = node.children
        return false unless node.type == :or_asgn && asgn.type == :ivasgn && instance.is_a?(AST::Types::Name::Instance) && method_name

        only_writer?(constr, instance, asgn.children[0], method_name) && KeyedMemo.settled?(constr, instance, value)
      end

      # What `node` evaluates to, read off its nodes as `literal_operand_type`
      # does, through the arms of a conditional that may run.
      def self.value(constr, node, type)
        if %i[begin kwbegin].include?(node.type) && (last = node.children.last)
          return value(constr, last, constr.typing.recorded_type_of(node: last) || type)
        end
        return constr.literal_operand_type(node, type) unless node.type == :if

        flow = Specializations::Evals::Flow.new(constr.typing)
        arms = node.children.drop(1).reject { |arm| arm && flow.dead?(arm) }
        values = arms.map { |arm| arm ? value(constr, arm, constr.typing.recorded_type_of(node: arm) || type) : AST::Builtin.nil_type }
        values.size == 1 ? values.first : type
      end

      def self.only_writer?(constr, instance, ivar, method_name)
        constr.checker.factory.definition_builder.build_instance(instance.name).ancestors.ancestors.all? do |ancestor|
          constr.constructor_bindings.method_bodies(ancestor.name.to_s).all? do |name, bodies|
            bodies.all? { |body| body && (!body.writes.include?(ivar) || (name == method_name && body.memoizes == ivar)) }
          end
        end
      rescue RBS::BaseError
        false
      end
    end
  end
end

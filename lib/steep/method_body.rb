module Steep
  # A method body checked against the return its declaration states, or —
  # where every call of the method was answered — what those calls returned
  # (`Specializations::CallSiteUnions`) checked against it in its place.
  module MethodBody
    class << self
      # `setters`: report a setter's mismatch as one, which only an instance
      # method body does.
      def check(constr, node, body_node, setters:)
        return_type = constr.expand_alias(constr.method_context!.return_type)
        return constr.synthesize(body_node) if return_type.is_a?(AST::Types::Void)

        answer = Specializations::CallSiteUnions.body_answer(constr, node)
        pair = constr.check(body_node, return_type) do |_, actual_type, result|
          report(constr, node, actual_type, result, setters: setters) unless answer
        end
        return pair unless answer

        result = constr.check_relation(sub_type: answer, super_type: return_type)
        report(constr, node, answer, result, setters: setters) if result.failure?
        constr.add_typing(body_node, type: answer, constr: pair.constr)
      end

      private

      def report(constr, node, actual_type, result, setters:)
        context = constr.method_context!
        error =
          if setters && context.attribute_setter?
            Diagnostic::Ruby::SetterBodyTypeMismatch.new(
              node: node, expected: context.return_type, actual: actual_type, result: result, method_name: context.name
            )
          else
            Diagnostic::Ruby::MethodBodyTypeMismatch.new(node: node, expected: context.return_type, actual: actual_type, result: result)
          end
        constr.typing.add_error(error)
      end
    end
  end
end

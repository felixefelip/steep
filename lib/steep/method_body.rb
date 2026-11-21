module Steep
  # A method body checked against the return its declaration states, or —
  # where every call of the method was answered — what those calls returned
  # (`Specializations::CallSiteUnions`) checked against it in its place.
  module MethodBody
    class << self
      # `setters`: report a setter's mismatch as one, which only an instance
      # method body does.
      def check(constr, node, body_node, setters:)
        selves = Specializations::CallSiteUnions.body_selves(constr, node)
        return checked(constr, node, body_node, setters: setters) unless selves

        errors = constr.typing.errors
        generic = errors.size
        pair = checked(constr, node, body_node, setters: setters)
        return pair if errors.size == generic

        on_selves = selves.flat_map { |self_type| errors_on(constr, node, body_node, self_type, setters: setters) || (return pair) }
        reported = on_selves.to_set { |error| error_key(error) }
        kept = errors.drop(generic).select { |error| reported.include?(error_key(error)) }
        errors.slice!(generic..)
        errors.concat(kept)
        pair
      end

      private

      # What the body reports checked on `self_type`, its declared parameters
      # unchanged, so only to tell which generic errors a real self has too:
      # with a precise self and generic parameters it may report what no call
      # does. Nothing it types is kept: the generic check's typing stays.
      def errors_on(constr, node, body_node, self_type, setters:)
        definition = definition_of(constr, self_type) or return nil
        args_node = node.type == :defs ? node.children[2] : node.children[1]
        child = constr.with_new_typing(constr.typing.new_child)
        child.with_method_constr(constr.method_context!.name, node, args: args_node.children, self_type: self_type, definition: definition) do |method_constr|
          checked(method_constr.synthesize_children(args_node), node, body_node, setters: setters)
        end
        child.typing.errors
      end

      def error_key(error) = [error.class, error.location&.begin_pos, error.location&.end_pos]

      def definition_of(constr, self_type)
        builder = constr.checker.factory.definition_builder
        return nil unless self_type.is_a?(AST::Types::Name::Base) && builder.env.module_class_entry(self_type.name)

        case self_type
        when AST::Types::Name::Singleton then builder.build_singleton(self_type.name)
        when AST::Types::Name::Instance then builder.build_instance(self_type.name)
        end
      rescue RBS::BaseError
        nil
      end

      def checked(constr, node, body_node, setters:)
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

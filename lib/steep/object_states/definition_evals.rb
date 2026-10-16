module Steep
  module ObjectStates
    module DefinitionEvals
      STRING_DEFINERS = Set["::Module#class_eval", "::Module#module_eval"].freeze

      class << self
        # A string evaluated on `self` that only defines methods: running it
        # changes nothing `self` holds.
        def defines_only?(constr, node)
          call = ObjectStates.recorded_call(constr, node)
          return false unless call.is_a?(TypeInference::MethodCall::Typed) && !call.method_decls.empty?
          return false unless call.method_decls.all? { |decl| STRING_DEFINERS.include?(MethodIdentity.normalize(decl.method_name.to_s)) }

          _, _, *arguments = node.children
          source = arguments.size == 1 && constr.typing.has_type?(arguments[0]) && constr.typing.type_of(node: arguments[0])
          return false unless source.is_a?(AST::Types::Literal) && source.value.is_a?(::String)

          parsed = Prism.parse(source.value)
          parsed.errors.empty? && parsed.value.statements.body.all? { |statement| statement.is_a?(Prism::DefNode) }
        end
      end
    end
  end
end

module Steep
  # What `X.class_eval(source)` returns: the value of `source`'s last
  # expression, evaluated with `X` as self and as the constant scope. That is
  # what `class ::X; source; end` evaluates to, so the source is checked as the
  # body of that reopening, in a typing of its own whose diagnostics are
  # dropped, and only the type of its last statement is kept.
  #
  # Only for a source the call site fixes: a string that does not fold is code
  # nobody here can read, and the call keeps its declared `untyped`.
  module StringEvalIntrinsics
    KEYS = Set["::Module#module_eval", "::Module#class_eval"].freeze

    class << self
      def fold(constr, call:, receiver_type:, argument_types:)
        return nil unless KEYS.include?(MethodIdentity.key(call))

        receiver_type = Specializations.exact_self(constr) || constr.self_type if receiver_type.is_a?(AST::Types::Self)
        return nil unless receiver_type.is_a?(AST::Types::Name::Singleton)

        text = argument_types.first
        return nil unless text.is_a?(AST::Types::Literal) && text.value.is_a?(String)

        last_statement_type(constr, receiver_type.name, text.value)
      end

      private

      def last_statement_type(constr, type_name, text)
        factory = constr.checker.factory
        keyword = factory.env.module_entry(type_name) ? "module" : "class"
        source = Source.parse("#{keyword} #{type_name}\n#{text}\nend", path: constr.source.path, factory: factory)
        return nil unless source.node

        typing = Typing.new(source: source, root_context: constr.typing.root_context, cursor: nil)
        reopening = TypeConstruction.new(
          checker: constr.checker,
          source: source,
          annotations: source.annotations(block: source.node, factory: factory, context: nil),
          typing: typing,
          context: typing.root_context,
          contracts: constr.contracts,
          postconditions: constr.postconditions,
          callbacks: constr.callbacks,
          specializations: constr.specializations,
          literal_method_registry: constr.literal_method_registry,
          delegation_registry: constr.delegation_registry,
          constructor_bindings: constr.constructor_bindings,
          return_forwarding: constr.return_forwarding,
          return_alias: constr.return_alias
        )
        reopening.synthesize(source.node)

        body = source.node.children.last or return AST::Builtin.nil_type
        last = body.type == :begin ? body.children.last : body
        return nil unless typing.has_type?(last)

        reopening.literal_operand_type(last, typing.type_of(node: last))
      rescue ::Parser::SyntaxError
        nil
      end
    end
  end
end

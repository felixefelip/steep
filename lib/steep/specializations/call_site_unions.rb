module Steep
  module Specializations
    # What a method returns across the whole program: the union of what each of
    # its calls returned, checked for what that call passes.
    #
    #   def self.has_many_like(name)
    #     class_eval "def #{Inflector.singularize(name.to_s)}_ids; []; end"
    #   end
    #
    #   has_many_like :posts         # :post_ids
    #   has_many_like :categories    # :category_ids
    #
    # The body checked under its declaration cannot say that: what
    # `singularize` answers depends on what the rules hold when the call is
    # made, and only the call knows. Every call is one of those two, so the
    # method returns `:post_ids | :category_ids`.
    #
    # Only where every call was answered. One left out — a call fixing no
    # value, one whose return was not specialized, one made through a receiver
    # that may be another class — can return anything the declaration allows.
    module CallSiteUnions
      class << self
        # Yields each project method in `keys` that a call in `typing` makes,
        # with what that call returns, or nil where `store` does not say.
        def each_answer(typing, keys, store, factory)
          typing.method_calls.each do |node, call|
            next unless call.respond_to?(:method_decls)

            called = call.method_decls.map { |decl| decl.method_name.to_s.delete_prefix("::") }.uniq & keys.to_a
            next if called.empty?

            answer = answer(node, typing, call, called, store, factory)
            called.each { |key| yield key, answer }
          end
        end

        # What the body of `def_node` answers in place of its own type, where
        # it is checked under its declaration rather than for one call.
        def body_answer(constr, def_node)
          store = constr.specializations
          return nil if store.empty? || constr.specialization_arguments(def_node)

          context = constr.method_context or return nil
          method = context.method or return nil
          store.declaration_type(key(context.name, method), factory: constr.checker.factory)
        end

        private

        # A union of literals passed in an argument is one of its members at
        # run time, so the call returns what one of those returned.
        def answer(node, typing, call, called, store, factory)
          return nil unless call.is_a?(TypeInference::MethodCall::Typed) && call.method_decls.size == 1 && called.size == 1
          return nil unless node.type == :send || Accumulators::LAMBDA_BODIES.include?(node.type)

          arguments = Arguments.recorded(node, typing) or return nil
          types = arguments.alternatives.map do |alternative|
            store.call_return_type(called.first, alternative, factory: factory) or return nil
          end

          AST::Types::Union.build(types: types)
        end

        # The key a call resolving to `method` is recorded under
        # (`Specializations.method_key`), spelled from the definition.
        def key(name, method)
          member = method.members.first
          separator = member.is_a?(RBS::AST::Members::Base) && member.kind == :singleton ? "." : "#"
          "#{method.defined_in.to_s.delete_prefix("::")}#{separator}#{name}"
        end
      end
    end
  end
end

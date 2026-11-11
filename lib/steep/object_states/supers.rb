module Steep
  module ObjectStates
    # A `super` is a call on `self`: it leaves `self`'s contents as the body it
    # reached left them, checked under them as any call on `self` is.
    module Supers
      def self.after(pair, node)
        constr = pair.constr
        constr.record_vouched_arguments(node.children)
        pair.with(constr: ObjectStates.after_call(constr, node: node, method_name: constr.method_context!.name, receiver: nil, receiver_type: constr.self_type, arguments: node.children))
      end

      # A core class's `initialize` sets no ivar of the project's
      # (`ObjectStates.initialize_chain`).
      def self.core_initializer?(call, node)
        node.type == :super && call.is_a?(TypeInference::MethodCall::Typed) && call.method_name == :initialize &&
          call.method_decls.all? { |decl| Project::LiteralMethodRegistry::CORE_CLASSES.include?(decl.method_name.type_name.to_s.delete_prefix("::")) }
      end
    end
  end
end

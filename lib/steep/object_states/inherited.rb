module Steep
  module ObjectStates
    # Ruby runs `Superclass.inherited(subclass)` where `class Sub < Superclass`
    # creates the class, before its body. Where the project defines that hook,
    # the body is checked as if it started with the call, so what the hook
    # leaves the new class holding is what the body starts with.
    module Inherited
      # The class body of `node` checked from `constr`, its constructor, under
      # what `outer` knew; nil for a class with nothing to check.
      def self.body_exit(constr, outer, node)
        _, super_node, body = node.children
        runs = runs?(constr, super_node)
        entered = ClassStates.entered(constr, outer, inherited_runs: runs)
        entered = left_by_hook(entered.synthesize(hook = hook_call(super_node)).constr, hook) if runs
        body ? entered.synthesize(body).constr : (entered if runs)
      end

      # The new class holding what the hook's check left it holding.
      def self.left_by_hook(constr, hook)
        ivars = ObjectStates.exit_of(constr, hook, under: :stateful?)&.classes&.[](constr.self_type.name)
        ivars ? constr.update_type_env { |env| env.refine_types(instance_variable_types: ivars) } : constr
      end

      # Whether the hook runs here: the class is created by this body, the
      # one the project writes, under a superclass whose ancestry defines
      # `inherited` in the project.
      def self.runs?(constr, super_node)
        singleton = constr.self_type
        return false unless super_node&.type == :const && singleton.is_a?(AST::Types::Name::Singleton)

        registry = constr.constructor_bindings
        return false unless registry.class_bodies(singleton.name.to_s) <= 1

        ancestors = constr.checker.factory.definition_builder.build_singleton(singleton.name).ancestors.ancestors
        ancestors.drop(1).any? { |ancestor| registry.defines?(ancestor.name.to_s, :inherited, singleton: true) }
      rescue RBS::BaseError
        false
      end

      # Whether `node` hands the class its body creates to `inherited`, which
      # finds it holding nothing yet.
      def self.hook_call?(constr, node)
        receiver, name, method, argument = node.children
        node.type == :send && name == :send && receiver&.type == :const && method&.type == :sym && method.children[0] == :inherited &&
          argument&.type == :self && node.children.size == 4 && !constr.method_context
      end

      # The ivars the `inherited` hooks of a class's ancestors set on it
      # (`param_births`).
      def self.births(constr, singleton)
        ObjectStates.class_side_bodies(constr, singleton).flat_map { |_, name, body| name == :inherited && body&.param_births ? body.param_births.to_a : [] }
      end

      # The ivars a body sets on what its first parameter holds, with
      # `instance_variable_set`, to an empty hash or a new object.
      def self.param_births(args_node, body)
        param = args_node&.children&.first
        return Set[] unless param&.type == :arg

        born = Set[] #: Set[Symbol]
        LocalReach.each_node(body) do |node|
          receiver, method, ivar, value, *rest = node.children
          next unless node.type == :send && method == :instance_variable_set && receiver&.type == :lvar && receiver.children[0] == param.children[0]
          next unless rest.empty? && ivar&.type == :sym && value && ((value.type == :hash && value.children.empty?) || TypeInference::ConstructorBindingAnalyzer::HandedBack.fresh_object?(value))

          born << ivar.children[0]
        end
        born
      end

      # `Superclass.send(:inherited, self)`, written where the superclass is.
      def self.hook_call(super_node)
        range = super_node.location.expression
        map = ::Parser::Source::Map.new(range)
        name = ::Parser::AST::Node.new(:sym, [:inherited], location: map)
        new_class = ::Parser::AST::Node.new(:self, [], location: map)
        ::Parser::AST::Node.new(:send, [super_node, :send, name, new_class], location: ::Parser::Source::Map::Send.new(nil, range, nil, nil, range))
      end
    end
  end
end

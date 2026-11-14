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
        entered = entered.synthesize(hook_call(super_node)).constr if runs
        body ? entered.synthesize(body).constr : (entered if runs)
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

module Steep
  module Specializations
    # The body a call runs, which is the one its declaration names only where no
    # class the receiver may be at run time overrides the method:
    #
    #   class Base;  def self.tag(name) = "#{name}!"; end
    #   class Child < Base; def self.tag(name) = "#{name}?"; end
    #
    #   Child.tag(:a)    # resolves to Base's declaration when Child has none
    #   klass.tag(:a)    # klass: singleton(Base) may be Child
    #
    # A call that may run another body is not specialized: what Base's body
    # returns for `(:a)` is not what the call returns. Where every class the
    # receiver may be runs the same body, the call is keyed by that body, which
    # is the source's answer and not the signature's: an override the RBS does
    # not redeclare still runs, and a method the RBS places on a class whose
    # source inherits it runs the ancestor's body.
    #
    # Which body runs is `ObjectStates.resolved_body`'s question, so the source
    # it reads is the same: the project's `ConstructorBindingRegistry`, which a
    # check reading a sidecar has as well as the run that wrote it.
    class Overrides
      SUBCLASSES = ObjectSpace::WeakKeyMap.new

      def initialize(factory:, registry:)
        @factory = factory
        @registry = registry
      end

      # The key the call's body is recorded under, or nil where the call does
      # not name one body.
      #
      # `exact_self`: the class `self` is where the call is made, where that is
      # one class (`Specializations.exact_self`).
      def body_key(call, node:, exact_self:, self_type:)
        return nil unless call.is_a?(TypeInference::MethodCall::Typed)

        key = Specializations.method_key(call.method_decls) or return nil
        return key if node.type == :super

        run_key(call, key, node, exact_self, self_type)
      end

      private

      def run_key(call, key, node, exact_self, self_type)
        state = ObjectStates.state_in(call.receiver_type)
        receiver = state&.back_type || call.receiver_type
        receiver = exact_self || self_type if receiver.is_a?(AST::Types::Self)
        return key unless receiver.is_a?(AST::Types::Name::Singleton) || receiver.is_a?(AST::Types::Name::Instance)

        names = state || exact_receiver?(node, exact_self) ? [receiver.name] : [receiver.name, *subclasses(receiver.name)]
        keys = names.map { |name| ran_key(name, receiver.is_a?(AST::Types::Name::Singleton), call.method_decls.first, key) }.uniq
        keys.first if keys.size == 1
      end

      # A class object named by a constant, or `self` where it is one class.
      # Any other receiver of type `singleton(Base)` or `Base` may be a
      # subclass's; one whose state a constructor fixed (`ObjectState`) is the
      # class it was built as.
      def exact_receiver?(node, exact_self)
        send = Accumulators::LAMBDA_BODIES.include?(node.type) ? node.children[0] : node
        receiver = send.children[0]
        return !exact_self.nil? if receiver.nil? || receiver.type == :self

        receiver.type == :const
      end

      def ran_key(name, singleton, decl, key)
        builder = @factory.definition_builder
        definition = singleton ? builder.build_singleton(name) : builder.build_instance(name)
        method = definition.methods[decl.method_name.method_name] or return nil
        return nil unless method.defined_in == decl.method_def.defined_in

        source_key(definition, decl.method_name.method_name) || key
      rescue RBS::BaseError
        nil
      end

      def source_key(definition, method_name)
        definition.ancestors.ancestors.each do |ancestor|
          owner = ancestor.name.to_s.delete_prefix("::")
          if ancestor.is_a?(RBS::Definition::Ancestor::Singleton)
            return "#{owner}.#{method_name}" if method_name == :new ? @registry.initializers_for(owner).any? : ObjectStates.ancestor_defines?(@registry, ancestor, method_name)
          elsif ObjectStates.ancestor_defines?(@registry, ancestor, method_name)
            return "#{owner}##{method_name}"
          end
        end
        nil
      end

      def subclasses(name)
        env = @factory.env
        children = (SUBCLASSES[env] ||= direct_subclasses(env))
        found = [] #: Array[RBS::TypeName]
        queue = children.fetch(name, []).dup
        while (child = queue.shift)
          next if found.include?(child)

          found << child
          queue.concat(children.fetch(child, []))
        end
        found
      end

      def direct_subclasses(env)
        env.class_decls.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(name, entry), children|
          next unless entry.is_a?(RBS::Environment::ClassEntry)

          parent = entry.primary_decl.super_class&.name or next
          children[parent] << name
        end
      end
    end
  end
end

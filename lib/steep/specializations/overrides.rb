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
    # returns for `(:a)` is not what the call returns.
    #
    # `definitions`: the methods the project defines in source, by key
    # (`Collector.definitions`). An override that has no signature of its own is
    # visible only there; a check reading a sidecar has none, and sees the
    # overrides the signatures declare.
    class Overrides
      SUBCLASSES = ObjectSpace::WeakKeyMap.new

      def initialize(factory:, definitions:)
        @factory = factory
        @definitions = definitions
      end

      # The key the call's body is recorded under, or nil where the call does
      # not name one body.
      #
      # `exact_self`: the class `self` is where the call is made, where that is
      # one class (`Specializations.exact_self`).
      def body_key(call, node:, exact_self:, self_type:)
        return nil unless call.is_a?(TypeInference::MethodCall::Typed)

        key = Specializations.method_key(call.method_decls) or return nil
        return key unless @definitions.empty? || @definitions.include?(key)

        key if runs_declared_body?(call, key, node, exact_self, self_type)
      end

      private

      def runs_declared_body?(call, key, node, exact_self, self_type)
        receiver = call.receiver_type
        receiver = exact_self || self_type if receiver.is_a?(AST::Types::Self)
        return true unless receiver.is_a?(AST::Types::Name::Singleton) || receiver.is_a?(AST::Types::Name::Instance)

        names = exact_receiver?(node, exact_self) ? [receiver.name] : [receiver.name, *subclasses(receiver.name)]
        names.all? { |name| runs?(name, receiver.is_a?(AST::Types::Name::Singleton), call.method_decls.first, key) }
      end

      # A class object named by a constant, or `self` where it is one class.
      # Any other receiver of type `singleton(Base)` or `Base` may be a
      # subclass's.
      def exact_receiver?(node, exact_self)
        send = Accumulators::LAMBDA_BODIES.include?(node.type) ? node.children[0] : node
        receiver = send.children[0]
        return !exact_self.nil? if receiver.nil? || receiver.type == :self

        receiver.type == :const
      end

      def runs?(name, singleton, decl, key)
        builder = @factory.definition_builder
        definition = singleton ? builder.build_singleton(name) : builder.build_instance(name)
        method = definition.methods[decl.method_name.method_name] or return false
        return false unless method.defined_in == decl.method_def.defined_in

        source = nearest_source_key(name, singleton, decl.method_name.method_name)
        source.nil? || source == key
      rescue RBS::BaseError
        false
      end

      def nearest_source_key(name, singleton, method_name)
        return nil if @definitions.empty?

        builder = @factory.definition_builder.ancestor_builder
        ancestors = singleton ? builder.singleton_ancestors(name) : builder.instance_ancestors(name)
        ancestors.ancestors.each do |ancestor|
          owner = ancestor.name.to_s.delete_prefix("::")
          key = ancestor.is_a?(RBS::Definition::Ancestor::Singleton) ? "#{owner}.#{method_name}" : "#{owner}##{method_name}"
          return key if @definitions.include?(key)
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

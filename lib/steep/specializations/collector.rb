module Steep
  module Specializations
    # What one source file contributes to a specialization pass: the methods it
    # defines, and the argument tuples its call sites supply to methods the
    # project defines elsewhere.
    class Collector
      # `{ "Foo#bar" => def node }` for every method defined in `node`.
      def self.definitions(node)
        result = {} #: Hash[String, Parser::AST::Node]
        walk_defs(node, []) { |key, def_node| result[key] = def_node } if node
        result
      end

      # `{ "Foo#bar" => Set[Arguments] }` for the call sites in `typing` that
      # resolve to one method and fix at least one argument to a literal.
      def self.call_sites(typing)
        result = {} #: Hash[String, Set[Arguments]]

        typing.each_typing do |node, _type|
          next unless node.type == :send

          call = begin
                   typing.call_of(node: node)
                 rescue Typing::UnknownNodeError
                   next
                 end
          next unless call.is_a?(TypeInference::MethodCall::Typed)

          key = Specializations.method_key(call.method_decls) or next
          arguments = Arguments.from_send(node, typing) or next

          (result[key] ||= Set.new) << arguments
        end

        result
      end

      def self.walk_defs(node, nesting, &block)
        return unless node.is_a?(Parser::AST::Node)

        case node.type
        when :class, :module
          name = const_name(node.children[0])
          inner = name ? nesting + [name] : nesting
          body = node.type == :class ? node.children[2] : node.children[1]
          walk_defs(body, inner, &block)
        when :def
          yield "#{nesting.join("::")}##{node.children[0]}", node unless nesting.empty?
        when :defs
          yield "#{nesting.join("::")}.#{node.children[1]}", node unless nesting.empty?
        when :sclass
          walk_sclass_defs(node, nesting, &block)
        else
          node.children.each { |child| walk_defs(child, nesting, &block) }
        end
      end

      # `class << self` holds singleton methods of the enclosing class, written
      # as plain `def`s. `class << obj` holds singleton methods of that object,
      # which no class name keys.
      def self.walk_sclass_defs(node, nesting, &block)
        return unless node.children[0].type == :self

        walk_defs(node.children[1], nesting) do |key, def_node|
          yield key.sub("#", "."), def_node
        end
      end

      def self.const_name(node)
        return nil unless node.is_a?(Parser::AST::Node) && node.type == :const

        parent = node.children[0]
        return node.children[1].to_s if parent.nil? || parent.type == :cbase

        prefix = const_name(parent) or return nil
        "#{prefix}::#{node.children[1]}"
      end

      private_class_method :walk_defs, :walk_sclass_defs, :const_name
    end
  end
end

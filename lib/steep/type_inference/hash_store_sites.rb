module Steep
  module TypeInference
    # Whether every store into the hash a class memo keeps
    # (`ConstructorBindingAnalyzer::Body#memoized_hash`) is made by a class body
    # on its own class:
    #
    #   class Base
    #     def self.registry = @registry ||= {}
    #     def self.register(name, value) = registry[name] = value
    #   end
    #
    #   class Car < Base
    #     register :wheel, Wheel.new    # a store made by Car's body
    #   end
    #
    # A store is `memo[key] = value`, `memo.store(key, value)` or an operator
    # assignment to `memo[key]`, on the memo or on its ivar, and a call of a
    # class method that makes one on `self`. Each has to be a statement of a
    # class body made on `self`, outside any block, or be made on `self` by
    # such a method. A string or a symbol naming one may reach it by a path no
    # call shows, so it counts as a store made elsewhere.
    class HashStoreSites
      STORES = %i[[]= store].freeze
      OP_ASSIGNS = %i[op_asgn or_asgn and_asgn].freeze

      def initialize(nodes, memo:, ivar:)
        @nodes = nodes
        @memo = memo
        @ivar = ivar
      end

      def class_bodies_only?
        bodies = Hash.new { |hash, name| hash[name] = [] } #: Hash[Symbol, Array[::Parser::AST::Node?]]
        @nodes.each { |node| each_class_method(node, false) { |name, body| bodies[name] << body } }
        storing = storing_methods(bodies)

        @nodes.all? { |node| made_by_class_bodies?(node, :other, storing) }
      end

      private

      def each_class_method(node, in_sclass, &block)
        return unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :defs
          yield node.children[1], node.children[3] if node.children[0].type == :self
          return
        when :def
          yield node.children[0], node.children[2] if in_sclass
          return
        when :sclass
          return each_class_method(node.children[1], node.children[0].type == :self, &block)
        when :class, :module
          in_sclass = false
        end
        node.children.each { |child| each_class_method(child, in_sclass, &block) }
      end

      def storing_methods(bodies)
        storing = Set[] #: Set[Symbol]
        loop do
          grown = bodies.keys.reject { |name| storing.include?(name) }.select do |name|
            bodies[name].any? { |body| any_node?(body) { |node| store?(node) || self_call?(node, storing) } }
          end
          return storing if grown.empty?

          storing.merge(grown)
        end
      end

      # `context`: `:class_body` in a class or module body, `:sclass` in
      # `class << self`, `[:def, name]` in a class method, `:other` anywhere
      # else.
      def made_by_class_bodies?(node, context, storing)
        return true unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :class, :module
          return made_by_class_bodies?(node.children.last, :class_body, storing)
        when :defs
          return made_by_class_bodies?(node.children[3], node.children[0].type == :self ? [:def, node.children[1]] : :other, storing)
        when :def
          return made_by_class_bodies?(node.children[2], context == :sclass ? [:def, node.children[0]] : :other, storing)
        when :sclass
          return made_by_class_bodies?(node.children[1], node.children[0].type == :self ? :sclass : :other, storing)
        when :block, :numblock
          return made_by_class_bodies?(node.children[0], context, storing) && made_by_class_bodies?(node.children[2], :other, storing)
        when :sym, :str
          return !named?(node.children[0].to_s, storing)
        end
        return false if (store?(node) || storing_call?(node, storing)) && !permitted?(node, context, storing)

        node.children.all? { |child| made_by_class_bodies?(child, context, storing) }
      end

      def permitted?(node, context, storing)
        return false unless on_self?(node)

        context == :class_body || (context.is_a?(Array) && storing.include?(context[1]))
      end

      def store?(node)
        case node.type
        when :send
          STORES.include?(node.children[1]) && held?(node.children[0])
        when :indexasgn
          held?(node.children[0])
        when *OP_ASSIGNS
          target = node.children[0]
          %i[send indexasgn].include?(target.type) && (target.type == :indexasgn || target.children[1] == :[]) && held?(target.children[0])
        else
          false
        end
      end

      def held?(receiver)
        return false unless receiver.is_a?(::Parser::AST::Node)

        (receiver.type == :send && receiver.children[1] == @memo && receiver.children.size == 2) ||
          (receiver.type == :ivar && receiver.children[0] == @ivar)
      end

      def on_self?(node)
        receiver = store?(node) ? memo_receiver(node) : node.children[0]
        receiver.nil? || receiver.type == :self
      end

      # What the memo is called on, or nil for its ivar, which is `self`'s.
      def memo_receiver(node)
        target = OP_ASSIGNS.include?(node.type) ? node.children[0] : node
        held = target.children[0]
        held.type == :ivar ? nil : held.children[0]
      end

      def storing_call?(node, storing)
        %i[send csend].include?(node.type) && storing.include?(node.children[1])
      end

      def self_call?(node, storing)
        storing_call?(node, storing) && (node.children[0].nil? || node.children[0].type == :self)
      end

      def named?(text, storing)
        [@memo, @ivar, *storing].any? { |name| text.match?(/(?<![\w@])#{Regexp.escape(name.to_s)}(?!\w)/) }
      end

      def any_node?(node, &block)
        return false unless node.is_a?(::Parser::AST::Node)
        return true if yield(node)

        node.children.any? { |child| any_node?(child, &block) }
      end
    end
  end
end

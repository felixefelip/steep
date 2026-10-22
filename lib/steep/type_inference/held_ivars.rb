module Steep
  module TypeInference
    # The ivars of `self` one method body reaches only through calls made on
    # them, in order, the way `HeldLocals` reads a local (felixefelip/steep#312):
    #
    #   @foo = Foo.new({})
    #   foo.my_hash[:bar] = 10
    #
    # An ivar qualifies when every mention of it — `@foo`, or a reader of it
    # called on `self` — is the receiver of a call and the only mention in it,
    # and every assignment to it is a statement of the body, outside anything
    # that may run later or again. A value assigned to it is then held
    # (`held_value?`) as a local's is.
    class HeldIvars < HeldLocals
      # `reader`: the ivar a method of `self` called with no arguments answers,
      # or nil.
      def initialize(def_node, reader)
        @reader = reader
        @initializer = def_node&.type == :def && def_node.children[0] == :initialize
        @names = Set[] #: Set[Symbol]
        @escaped = Set[] #: Set[Symbol]
        @values = {}.compare_by_identity #: Hash[::Parser::AST::Node, Symbol]
        analyze(def_node) if def_node
      end

      # Whether the body reaches `name` some way other than through calls made
      # on it. One it never mentions it does not reach at all.
      def escapes?(name)
        @escaped.include?(name)
      end

      private

      def analyze(def_node)
        body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
        mentioned = Set[] #: Set[Symbol]
        @escaped = Set[] #: Set[Symbol]
        @assigned = [] #: Array[[Symbol, ::Parser::AST::Node]]
        walk(body, [], detached: false) do |node, parents, detached|
          name = ivar_of(node) or next
          mentioned << name
          visit_ivar(node, name, parents, detached)
        end

        @names.merge(mentioned - @escaped)
        @assigned.each { |name, value| @values[value] = name if @names.include?(name) }
      end

      def visit_ivar(node, name, parents, detached)
        if node.type == :ivasgn
          value = node.children[1]
          value && !detached && statement?(node, parents) ? @assigned << [name, value] : @escaped << name
        elsif detached || !received?(node, parents, name)
          @escaped << name
        end
      end

      # A statement of the body whose value nothing takes: not its last one,
      # which the method answers, unless the method is an `initialize`, whose
      # value `new` drops.
      def statement?(node, parents)
        return parents.empty? || (parents.size == 1 && parents[0].type == :begin) if @initializer

        parents.size == 1 && parents[0].type == :begin && !parents[0].children.last.equal?(node)
      end

      def ivar_of(node)
        case node.type
        when :ivar, :ivasgn then node.children[0]
        when :send then @reader.call(node.children[1]) if node.children.size == 2 && (node.children[0].nil? || node.children[0].type == :self)
        end
      end

      def received?(node, parents, name)
        call = parents.last
        call && CALLS.include?(call.type) && call.children[0].equal?(node) && mentions(call, name) == 1
      end

      def mentions(node, name)
        return 0 unless node.is_a?(::Parser::AST::Node)

        (ivar_of(node) == name ? 1 : 0) + node.children.sum { |child| mentions(child, name) }
      end
    end
  end
end

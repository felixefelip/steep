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
      # or nil. `taken`: whether a caller may take what a method of a name
      # answers.
      def initialize(def_node, reader, taken)
        @reader = reader
        @answer_dropped = !!def_node && def_node.type == :def && !taken.call(def_node.children[0])
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
        @assigned.each { |name, value| branch_values(value).each { |leaf| @values[leaf] = name } if @names.include?(name) }
      end

      def visit_ivar(node, name, parents, detached)
        if node.type == :ivasgn
          value = node.children[1]
          statement, around = value ? [node, parents] : [parents[-2], parents[0...-2] || []]
          value ||= parallel_value(node, parents)
          value && !detached && statement?(statement, around) ? @assigned << [name, value] : @escaped << name
        elsif detached || !received?(node, parents, name)
          @escaped << name
        end
      end

      # A statement of the body whose value nothing takes, or a branch of one:
      # not the body's last one, which the method answers, unless the method
      # is an `initialize`, whose value `new` drops, or one no call takes the
      # answer of.
      def statement?(node, parents)
        parent = parents.last
        return @initializer || @answer_dropped if parent.nil?

        case parent.type
        when :begin then !parent.children.last.equal?(node) || statement?(parent, parents[0...-1])
        when :if then !parent.children[0].equal?(node) && statement?(parent, parents[0...-1])
        else false
        end
      end

      # The values an assignment of `node` may store: each branch's, through
      # an `if` and the last statement of a `begin`.
      def branch_values(node)
        case node&.type
        when :if then node.children.drop(1).compact.flat_map { |branch| branch_values(branch) }
        when :begin then branch_values(node.children.last)
        else [node]
        end
      end

      # The value `@a, @b = x, y` assigns `node`, the target at its index.
      def parallel_value(node, parents)
        mlhs, masgn = parents.last(2).reverse
        values = masgn&.children&.[](1)
        return unless mlhs&.type == :mlhs && values&.type == :array && values.children.none? { |value| value.type == :splat }

        index = mlhs.children.index { |target| target.equal?(node) } or return
        values.children[index]
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

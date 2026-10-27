module Steep
  module Postconditions
    # Whether a method runs the block it is handed exactly once before it
    # returns, read off its body as its check typed it (felixefelip/steep#370):
    #
    #   def synchronize
    #     raise ThreadError, "must be called with a block" unless block_given?
    #     lock
    #     begin
    #       yield
    #     ensure
    #       unlock
    #     end
    #   end
    #
    # Every way out but a raise passes one `yield`. A branch typed `bot` has no
    # normal exit, so it has nothing to count.
    module RunsBlock
      NEVER = :never

      module_function

      def once?(def_node, typing)
        body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
        yields(body, typing) == 1
      end

      # How many `yield`s every normal exit of `node` has run: `NEVER` where it
      # has none, nil where they differ or are not counted.
      def yields(node, typing)
        return 0 unless node.is_a?(::Parser::AST::Node)
        return NEVER if !counted?(node) && typing.has_type?(node) && typing.type_of(node: node).is_a?(AST::Types::Bot)

        case node.type
        when :yield then counted?(node.children) ? nil : 1
        when :begin, :kwbegin, :ensure then sequence(node.children, typing)
        when :if then conditional(node.children[0], node.children.drop(1), typing)
        when :case then conditional(node.children[0], case_branches(node), typing)
        else counted?(node) ? nil : 0
        end
      end

      def sequence(nodes, typing)
        nodes.sum do |node|
          count = yields(node, typing)
          return count if count.nil? || count == NEVER

          count
        end
      end

      def conditional(predicate, branches, typing)
        return unless yields(predicate, typing) == 0

        counts = branches.map { |branch| yields(branch, typing) or return }.uniq - [NEVER]
        return NEVER if counts.empty?

        counts.first if counts.size == 1
      end

      # A `when`'s tests run before its body, and a test that runs a block
      # counts as one this does not follow. A missing `else` is a branch that
      # runs nothing.
      def case_branches(node)
        *whens, otherwise = node.children.drop(1)
        return [nil] if whens.any? { |clause| counted?(clause.children[0...-1]) }

        whens.map { |clause| clause.children.last } << otherwise
      end

      # Whether `node` holds a `yield` or a jump, which this does not follow.
      def counted?(node)
        return node.any? { |child| counted?(child) } if node.is_a?(Array)
        return false unless node.is_a?(::Parser::AST::Node)

        node.type == :yield || Accumulators::JUMPS.include?(node.type) || node.children.any? { |child| counted?(child) }
      end
    end
  end
end

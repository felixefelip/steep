module Steep
  module Specializations
    # What the `return`s of a method body hand back, which the body's own type
    # leaves out: `return result if done` answers `result` whatever the last
    # statement evaluates to.
    #
    # A `return` in an arm the checker reported `UnreachableBranch` for does not
    # run. Every other one counts, in a block too, since it leaves the method.
    # One inside a lambda, or a nested definition, leaves only that.
    module Returns
      SCOPES = %i[def defs class module sclass].freeze

      class << self
        # The returned types, or nil where one has no type to read: `return a, b`
        # is checked as an array node the typing does not keep.
        def values(typing, body)
          unreachable = typing.errors.filter_map { |error| error.node if error.is_a?(Diagnostic::Ruby::UnreachableBranch) }.to_set
          values = [] #: Array[AST::Types::t]

          each_return(body, unreachable.compare_by_identity) do |node|
            value = node.children[0]
            return nil if node.children.size > 1 || (value && !typing.has_type?(value))

            values << (value ? typing.type_of(node: value) : AST::Builtin.nil_type)
          end

          values
        end

        private

        def each_return(node, unreachable, &block)
          return unless node.is_a?(Parser::AST::Node)
          return if unreachable.include?(node) || SCOPES.include?(node.type) || lambda?(node)

          yield node if node.type == :return
          node.children.each { |child| each_return(child, unreachable, &block) }
        end

        def lambda?(node)
          %i[block numblock itblock].include?(node.type) && node.children[0].type == :lambda
        end
      end
    end
  end
end

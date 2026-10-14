module Steep
  module Specializations
    # What the `return`s of a method body hand back, which the body's own type
    # leaves out.
    module Returns
      class << self
        # The returned types, or nil where one has no type to read.
        def values(typing, body)
          flow = Evals::Flow.new(typing)
          values = [] #: Array[AST::Types::t]

          Accumulators.each_returns(body) do |node|
            next if flow.dead?(node)
            return nil if node.type == :return && node.children.size > 1
            return nil unless node.type == :return || typing.has_type?(node)

            values << (node.type == :return ? AST::Builtin.nil_type : typing.type_of(node: node))
          end

          values
        end
      end
    end
  end
end

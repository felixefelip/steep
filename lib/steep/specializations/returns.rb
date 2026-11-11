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

          Accumulators::ReturnedValues.each_returns(body) do |node|
            next if flow.dead?(node)
            return nil if node.type == :return && node.children.size > 1
            return nil unless node.type == :return || typing.has_type?(node)

            values << (node.type == :return ? AST::Builtin.nil_type : typing.type_of(node: node))
          end

          values
        end

        # What a body evaluates to across its ends, or nil where one is not
        # typed.
        def body_type(typing, def_node)
          return nil unless typing

          body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
          return nil unless body && typing.has_type?(body)

          values = values(typing, body) or return nil
          types = [typing.type_of(node: body), *values].reject { |type| type.is_a?(AST::Types::Bot) }
          return nil if types.empty? || types.any? { |type| type.is_a?(AST::Types::Any) }

          AST::Types::Union.build(types: types.reject { |type| type.is_a?(AST::Types::ObjectState) && types.include?(type.back_type) })
        end
      end
    end
  end
end

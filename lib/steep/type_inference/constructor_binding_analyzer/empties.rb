module Steep
  module TypeInference
    class ConstructorBindingAnalyzer
      module Empties
        module_function

        def of(body)
          return Set[] unless body.is_a?(::Parser::AST::Node)

          stmts = %i[begin kwbegin].include?(body.type) ? body.children : [body]
          stmts.grep(::Parser::AST::Node).flat_map { |stmt| assignments(stmt) }.filter_map do |target, value|
            target.children[0] if target.type == :ivasgn && value&.type == :array && value.children.empty?
          end.to_set
        end

        # A parallel assignment pairs its targets with its values only where
        # they are written out one per target: a splat on either side
        # otherwise moves the values after it.
        def assignments(stmt)
          return [[stmt, stmt.children[1]]] unless stmt.type == :masgn

          targets, values = stmt.children
          return [] unless values.type == :array && values.children.size == targets.children.size && values.children.none? { |value| value.type == :splat }

          targets.children.zip(values.children)
        end
      end
    end
  end
end

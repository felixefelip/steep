module Steep
  module Specializations
    module CalleeSelf
      # What `self` is inside the method `node` calls: its receiver, or — for a
      # call written on `self`, explicitly or not — the self of the frame the
      # call sits in. nil for a receiver naming no one class, which leaves the
      # body to the self its definition gives it.
      def self.of(typing, node)
        type = typing.call_of(node: node).receiver_type
        type = typing.self_type_of_call(node: node) if type.is_a?(AST::Types::Self)

        case type
        when AST::Types::Name::Singleton, AST::Types::Name::Instance then type
        when AST::Types::Intersection then lexical_self(typing, node, type)
        end
      end

      # A module body's `self` is that module, whatever an annotation adds to
      # it. A concern is annotated `singleton(Host) & singleton(Concern)` so its
      # body types against what the host has — but a call it makes there RUNS
      # on the module:
      #
      #   module Labels
      #     delegate :human_name, to: :class   # self is Labels, not the host
      #   end
      #
      # So of an intersection of class objects, the one the call is lexically
      # written in. Any other intersection names no one class.
      def self.lexical_self(typing, node, type)
        return nil unless type.types.all? { |component| component.is_a?(AST::Types::Name::Singleton) }

        name = enclosing_module(typing.source.node, node) or return nil
        type.types.find { |component| component.name.to_s.delete_prefix("::") == name }
      end

      # The name of the innermost `module`/`class` whose body holds `target`,
      # outside any `def` — a method body runs with a self of its own.
      def self.enclosing_module(root, target, nesting = [])
        return nil unless root.is_a?(::Parser::AST::Node)
        return nesting.empty? ? nil : nesting.join("::") if root.equal?(target)
        return nil if root.type == :def || root.type == :defs

        if root.type == :module || root.type == :class
          name = constant_name(root.children[0]) or return nil
          inner = name.start_with?("::") ? [name.delete_prefix("::")] : nesting + [name]
          body = root.type == :module ? root.children[1] : root.children[2]
          return enclosing_module(body, target, inner)
        end

        root.children.each do |child|
          found = enclosing_module(child, target, nesting)
          return found if found
        end
        nil
      end

      def self.constant_name(node)
        return nil unless node&.type == :const

        parent, name = node.children
        return name.to_s unless parent
        return "::#{name}" if parent.type == :cbase

        prefix = constant_name(parent) or return nil
        "#{prefix}::#{name}"
      end
    end
  end
end

module Steep
  module TypeInference
    class ConstructorBindingAnalyzer
      # What a class or module body runs besides defining methods: `true` for
      # any other code, the names its `include`, `extend` and `prepend` of
      # constants mix in, or nil for none. A nested `module`, or `class` with
      # no superclass, runs its own body's code, as the outer body does. How a
      # mixed-in constant is named is the caller's: `mixed` is handed each
      # argument and the nesting it is written in.
      module BodyCode
        module_function

        # Whether a `class`/`module` body sets nothing on the class: it runs
        # no code but definitions and mixins of modules with no hook, and a
        # `class` names no superclass whose `inherited` it would run.
        def inert?(node, typing, registry)
          return false unless node.type == :module || node.children[1].nil?

          code = code(node.children.last, []) { |argument, _| mixed_in(argument, typing) }
          code.nil? || (code != true && code.any? { |mixed| registry.inert?(mixed) })
        end

        def mixed_in(argument, typing)
          type = typing.type_of(node: argument) if typing.has_type?(argument)
          type.is_a?(AST::Types::Name::Singleton) ? [type.name.to_s.delete_prefix("::")] : []
        end

        def code(body, nesting, &mixed)
          mixins = [] #: Array[String]
          each_stmt(body) do |stmt|
            next if %i[def defs].include?(stmt.type)

            names = nested_code(stmt, nesting, &mixed) || mixed_names(stmt, nesting, &mixed) or return true
            mixins.concat(names)
          end
          mixins.empty? ? nil : mixins
        end

        def nested_code(stmt, nesting, &mixed)
          return unless stmt.type == :module || (stmt.type == :class && stmt.children[1].nil?)

          name = const_to_name(stmt.children[0]) or return
          code = code(stmt.children.last, nesting + [name], &mixed)
          code == true ? nil : code || []
        end

        def mixed_names(stmt, nesting, &mixed)
          return unless stmt.type == :send && (stmt.children[0].nil? || stmt.children[0].type == :self)
          return unless %i[include extend prepend].include?(stmt.children[1])

          arguments = stmt.children.drop(2)
          return if arguments.empty? || arguments.any? { |argument| argument.type != :const }

          arguments.flat_map { |argument| mixed.call(argument, nesting) }
        end

        def each_stmt(body)
          return unless body.is_a?(::Parser::AST::Node)

          stmts = body.type == :begin || body.type == :kwbegin ? body.children : [body]
          stmts.each { |s| yield s if s.is_a?(::Parser::AST::Node) }
        end

        def const_to_name(node)
          return nil unless node.is_a?(::Parser::AST::Node) && node.type == :const

          scope, name = node.children
          case scope&.type
          when nil, :cbase
            name.to_s
          when :const
            prefix = const_to_name(scope)
            prefix ? "#{prefix}::#{name}" : name.to_s
          end
        end
      end
    end
  end
end

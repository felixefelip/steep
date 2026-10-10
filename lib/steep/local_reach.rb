module Steep
  # What reaches a local of one method body other than its own name. Shared by
  # the analyses that vouch for a value only while nothing else can reach it:
  # `Accumulators`, `LocalAssignments` and `TypeInference::HeldLocals`.
  module LocalReach
    # Nodes that open a body of their own. A local named inside one is a
    # different variable that happens to share a name.
    SCOPES = %i[def defs class module sclass].freeze

    # Nodes whose body closes over the locals around it but runs on its own
    # schedule.
    CLOSURES = %i[block numblock].freeze

    # Loops whose condition and body both run once per turn.
    REPEATS = %i[while until while_post until_post].freeze

    # Receiverless calls that read or write any local by a name given as a
    # value, so no mention of it is written.
    REFLECTIVE = %i[binding eval local_variable_get local_variable_set].freeze

    module_function

    # Every node of `node`, stopping at a body of its own.
    def each_node(node, &block)
      return unless node.is_a?(Parser::AST::Node)
      return if SCOPES.include?(node.type)

      yield node
      node.children.each { |child| each_node(child, &block) }
    end

    # How many times `node` reads or writes `name`.
    def mentions(node, name)
      count = 0
      each_node(node) do |child|
        count += 1 if (child.type == :lvar || child.type == :lvasgn) && child.children[0] == name
      end
      count
    end

    def reflective?(body)
      each_node(body) do |node|
        return true if node.type == :send && node.children[0].nil? && REFLECTIVE.include?(node.children[1])
      end
      false
    end

    # The values a call made with `arguments` hands on: the positional ones
    # and the values of the keyword ones.
    def argument_values(arguments)
      arguments.flat_map do |argument|
        next [argument] unless argument.type == :kwargs

        argument.children.filter_map { |pair| pair.children[1] if pair.type == :pair }
      end
    end
  end
end

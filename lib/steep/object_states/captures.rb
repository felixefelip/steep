module Steep
  module ObjectStates
    # A block closed but for the locals it reads of the scope it is written in
    # (felixefelip/steep#275):
    #
    #   def set_backend(default_proc)
    #     @backend = Hash.new { |_hash, key| default_proc.call(key) }
    #   end
    #
    # It computes the same wherever it runs once those locals hold what they
    # held where it was written, which the call site's typing says. Only where
    # each holds a value that cannot change (`ObjectStates.state_value?`) and
    # nothing assigns it after the block is written: a block may run long
    # after, as a hash's default does.
    module Yields
      class << self
        # `[params, outer]`: the block's plain parameters, and the outer locals
        # its body reads, where that is all it reads of its scope. Nil where it
        # reads anything else, jumps, or assigns one of those locals.
        def captured(block)
          return unless block.type == :block

          memo = (@captured ||= ObjectSpace::WeakMap.new)
          return memo[block] if memo.key?(block)

          memo[block] = captured_of(block)
        end

        def captured_of(block)
          names = block.children[1].children.map { |param| %i[arg procarg0].include?(param.type) && param.children[0].is_a?(Symbol) ? param.children[0] : (return nil) }
          body = block.children[2] or return [names, Set[]]

          locals = Set.new(names)
          LocalReach.each_node(body) { |node| locals << node.children[0] if node.type == :lvasgn }
          outer = Set[]
          return unless !Tap.jumps?(body) && own?(body, locals, outer)
          return if outer.intersect?(locals - names)

          [names, outer]
        end

        # The parameters of `block`, closed under `captures`.
        def params_under(block, captures)
          return closed_params(block) if captures.empty?

          names, outer = captured(block)
          names if outer && !outer.empty? && outer == captures.keys.to_set && written_captured?(block, outer)
        end

        def written_captured?(block, outer)
          memo = (@written_captured ||= ObjectSpace::WeakMap.new)
          return memo[block] if memo.key?(block)

          written = parsed(source(block), outer.to_a)
          memo[block] = !!written && captured(written)&.last == outer
        end

        # What each outer local `block` reads holds where it is written, or
        # `{}` where one of them holds what may change.
        def captures(block, typing)
          _, outer = captured(block)
          return {} if outer.nil? || outer.empty?

          reads = {} #: Hash[Symbol, Parser::AST::Node]
          LocalReach.each_node(block.children[2]) { |node| reads[node.children[0]] ||= node if node.type == :lvar && outer.include?(node.children[0]) }
          outer.to_h do |name|
            read = reads[name]
            type = read && typing.has_type?(read) && typing.type_of(node: read)
            return {} unless type && ObjectStates.state_value?(type) && !assigned_after?(typing.source.node, block, name)

            [name, type]
          end
        end

        # Whether the body `block` is written in assigns `name` after it.
        def assigned_after?(root, block, name)
          scope = enclosing_scope(root, block) or return true
          start = block.loc.expression.end_pos
          found = false
          LocalReach.each_node(scope_body(scope)) do |node|
            found ||= %i[lvasgn op_asgn or_asgn and_asgn].include?(node.type) && assigned_name(node) == name && node.loc.expression.begin_pos >= start
          end
          found
        end

        def assigned_name(node) = node.type == :lvasgn ? node.children[0] : node.children[0].children[0]

        def enclosing_scope(node, block)
          return unless node.is_a?(Parser::AST::Node) && (range = node.loc.expression)
          return unless range.begin_pos <= block.loc.expression.begin_pos && block.loc.expression.end_pos <= range.end_pos

          inner = node.children.lazy.filter_map { |child| enclosing_scope(child, block) }.first
          inner || (node if %i[def defs].include?(node.type))
        end

        def scope_body(scope) = scope.type == :defs ? scope.children[3] : scope.children[2]

        def captures_key(captures)
          captures.sort_by(&:first).map { |name, type| "#{name}: #{type}" }.join(", ")
        end
      end
    end
  end
end

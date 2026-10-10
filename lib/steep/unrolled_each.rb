module Steep
  # An `each` over a collection the checker knows, whose block may change a
  # String held by a local from out here, run as the program runs it: once per
  # element, in order, each pass starting from the locals the one before it
  # left, and the first `break` taken ending the call.
  #
  #     result = word.dup
  #     [[/ies\z/, "y"], [/s\z/, ""]].each { |(rule, replacement)| break if result.sub!(rule, replacement) }
  #     result   # "category" for "categories", "post" for "posts"
  #
  # Declined, leaving the locals `StringMutation` widened, wherever a pass
  # cannot say whether it stops: a jump other than `break`, a `break` under a
  # condition the checker left open or under anything but an `if`, or a pass
  # that cannot finish without taking one.
  module UnrolledEach
    OTHER_JUMPS = (Accumulators::JUMPS - [:break]).freeze
    NESTED = [*LocalReach::SCOPES, *LocalReach::CLOSURES, *LocalReach::REPEATS, :for].freeze

    module_function

    def apply(constr, node, entry:, receiver_type:, block_params:, block_body:, block_type_hint:, decls:)
      unwidened = block_body && constr.typing.unwidened_of(node: block_body) or return constr
      types = exit_types(constr, node, unwidened, entry: entry, receiver_type: receiver_type, block_params: block_params,
                                                  block_body: block_body, block_type_hint: block_type_hint, decls: decls)
      return constr unless types

      constr.update_type_env { |env| env.refine_types(local_variable_types: types) }
    end

    def exit_types(constr, node, unwidened, entry:, receiver_type:, block_params:, block_body:, block_type_hint:, decls:)
      return unless constr.iteration_intrinsic(decls)&.collect == :each
      return if jumps_other_than_break?(block_body)

      breaks = breaks_in(block_body, []) or return
      collection = constr.iterated_collection(node.children[0], receiver_type) or return
      env = starting_env(constr, entry, unwidened)
      carried = env.local_variable_types.keys

      collection.types.each do |element|
        bindings = IterationIntrinsics.element_bindings(block_params, element) or return
        pass = entry.with_new_typing(constr.typing.new_child).update_type_env { env.refine_types(local_variable_types: bindings) }
        body_type, context = pass.synthesize_block_body(node: node, block_body: block_body, block_type_hint: block_type_hint)

        taken = taken_break(pass.typing, breaks)
        return if taken == :open

        exit_env = taken ? pass.typing.break_env_of(node: taken) : context.type_env
        return if exit_env.nil? || (!taken && body_type.is_a?(AST::Types::Bot))

        env = exit_env.update(local_variable_types: exit_env.local_variable_types.slice(*carried))
        break if taken
      end

      unwidened.keys.to_h { |name| [name, env.local_variable_types.fetch(name)[0]] }
    end

    # The block's env with the method's locals unpinned — the runs are known,
    # so a write in one is what the next reads — and `overrides` in place of
    # what they were entered with.
    def starting_env(constr, entry, overrides = {})
      env = entry.context.type_env
      outer = constr.context.type_env.local_variable_types
      unpinned = outer.select { |name, (type, enforced)| enforced.nil? && env.local_variable_types[name] == [type, type] }
      unpinned.merge!(overrides.slice(*unpinned.keys).transform_values { |type| [type, nil] })
      env.merge(local_variable_types: unpinned)
    end

    def jumps_other_than_break?(node)
      return false unless node.is_a?(Parser::AST::Node)
      return true if OTHER_JUMPS.include?(node.type)

      node.children.any? { |child| jumps_other_than_break?(child) }
    end

    # Each `break` of this loop with the conditions that lead to it, outermost
    # first: `[[if node, :truthy | :falsy], …]`. Nil for one reached through
    # anything but `if` and a list of statements.
    def breaks_in(node, conditions, found = [])
      return found unless node.is_a?(Parser::AST::Node)
      return found if NESTED.include?(node.type)
      return found << [node, conditions] if node.type == :break

      node.children.each_with_index do |child, index|
        next unless child.is_a?(Parser::AST::Node)

        inner = conditions
        if node.type == :if
          return nil if index.zero? && breaks_in(child, [])&.any?

          inner = [*conditions, [node.children[0], index == 1 ? :truthy : :falsy]] unless index.zero?
        elsif node.type != :begin
          return nil if breaks_in(child, [])&.any?
        end

        breaks_in(child, inner, found) or return nil
      end

      found
    end

    # The first `break` the pass reached, nil for none, `:open` where a
    # condition on the way to one was left undecided.
    def taken_break(typing, breaks)
      breaks.each do |break_node, conditions|
        reached = conditions.all? do |condition, side|
          truthiness = IterationIntrinsics.truthiness(typing.has_type?(condition) ? typing.type_of(node: condition) : nil)
          return :open unless truthiness

          truthiness == side
        end
        return break_node if reached
      end

      nil
    end
  end
end

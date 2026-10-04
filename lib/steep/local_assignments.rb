module Steep
  # Assignments to a local whose TYPE the checker sets otherwise than from the
  # value's own type, because of how the method goes on to use the local.
  #
  # Two cases, both read off the source once per file:
  #
  # `pushed_births` — a local born from a call whose collection the checker
  # computed, which the method then pushes onto:
  #
  #     upcased = ["a", "b"].map(&:upcase)   # the call answers ["A", "B"]
  #     upcased << "C"                       # a tuple would demand "A" here
  #
  # The local holds what the call DECLARES instead, and `Accumulators` keeps
  # its contents. Readable or not: a local this cannot follow still must not
  # turn its first push into an error.
  #
  # `interpolated` — every assignment to a local the method reads ONLY as an
  # interpolation operand:
  #
  #     definition = if signature then signature else "..." end
  #     "def #{name}(#{definition})"
  #
  # A plain string is typed `::String`, so that `x = "a"; [x] << "b"` is not an
  # error. A local read only inside `#{}` hands its value to nothing that could
  # hold the literal type, so the checker keeps the literal its decided value
  # spells. `choices` holds the `if`s such a value is chosen by, so the checker
  # records which arm it kept (`TypeConstruction#record_arm`).
  module LocalAssignments
    Analysis = Struct.new(:pushed_births, :interpolated, :choices, keyword_init: true)

    class << self
      def analyze(node)
        # By identity: parser nodes compare structurally, and the same
        # assignment written in two methods is two assignments.
        pushed_births = {}.compare_by_identity #: Hash[untyped, bool]
        interpolated = {}.compare_by_identity #: Hash[untyped, bool]
        choices = {}.compare_by_identity #: Hash[untyped, bool]

        each_body(node) do |def_node, body|
          each_pushed_birth(body) { |assignment| pushed_births[assignment] = true }
          each_interpolated(def_node, body) do |assignment|
            interpolated[assignment] = true
            each_choice(assignment.children[1]) { |choice| choices[choice] = true }
          end
        end

        Analysis.new(pushed_births: pushed_births, interpolated: interpolated, choices: choices)
      end

      private

      # Every method body in the source, nested ones included: a `def` inside a
      # `def` is a body of its own, with locals of its own.
      def each_body(node, &block)
        return unless node.is_a?(Parser::AST::Node)

        if node.type == :def || node.type == :defs
          body = node.type == :defs ? node.children[3] : node.children[2]
          yield node, body if body
        end

        node.children.each { |child| each_body(child, &block) }
      end

      # Every `name = <call>` in the body whose `name` is the receiver of a
      # `<<` somewhere in it.
      def each_pushed_birth(body)
        pushed = Set.new #: Set[Symbol]
        each_node(body) do |node|
          next unless node.type == :send && node.children[1] == :<< && node.children[0]&.type == :lvar

          pushed << node.children[0].children[0]
        end
        return if pushed.empty?

        each_node(body) do |node|
          next unless node.type == :lvasgn && pushed.include?(node.children[0])

          yield node if Accumulators.built_call?(node.children[1])
        end
      end

      # Every assignment to a local that the body reads only as `"#{local}"`.
      def each_interpolated(def_node, body)
        reads = Hash.new(0) #: Hash[Symbol, Integer]
        interpolations = Hash.new(0) #: Hash[Symbol, Integer]
        assignments = [] #: Array[untyped]

        each_node(body) do |node|
          case node.type
          when :lvar
            reads[node.children[0]] += 1
          when :lvasgn
            assignments << node
          when :dstr
            node.children.each do |part|
              next unless part.type == :begin && part.children.size == 1 && part.children[0].type == :lvar

              interpolations[part.children[0].children[0]] += 1
            end
          end
        end

        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        params = args.is_a?(Parser::AST::Node) ? args.children.map { |arg| arg.children[0] } : []

        assignments.each do |assignment|
          name = assignment.children[0]
          next if params.include?(name) || reads[name].zero?
          next unless reads[name] == interpolations[name]

          yield assignment
        end
      end

      # The `if`s that choose which of a value's ends it evaluates to: the
      # arms of each, and the last statement of a `begin`.
      def each_choice(node, &block)
        return unless node.is_a?(Parser::AST::Node)

        case node.type
        when :if
          yield node
          each_choice(node.children[1], &block)
          each_choice(node.children[2], &block)
        when :begin
          each_choice(node.children.last, &block)
        end
      end

      # Every node of one body, stopping at a body of its own — its locals are
      # another method's.
      def each_node(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        return if Accumulators::SCOPES.include?(node.type)

        yield node
        node.children.each { |child| each_node(child, &block) }
      end
    end
  end
end

module Steep
  module Specializations
    # Which bodies cannot answer differently for what the block of their call
    # returns. Such a body's tuples are recorded for any block (`unread`), so a
    # caller whose block returns something else reads the same answer.
    #
    # A body reads the block's value where it yields, calls the block, or lets
    # it out (returns it, stores it, passes it as a value). Handing it on with
    # `&block`, or by `super`, reads it only where the callee's answer does: a
    # method of the project by the same question asked of its body, a declared
    # one where its block's return type variable is in its return type.
    module BlockReads
      READS = :reads
      HANDED = %i[send csend super zsuper].freeze
      NESTED = %i[def defs class module sclass].freeze

      # `{ key => READS | [[callee_key, declared_reads], ...] }` for the bodies
      # of `definitions` (`Collector.definitions`) typed in `typing`.
      def self.facts(typing, definitions)
        definitions.to_h do |key, def_node|
          [key, body_facts(typing, def_node)]
        end
      end

      # The keys of `facts` whose body cannot read the block's value. Methods
      # that hand the block to each other and nothing else read none of it.
      def self.unread(facts)
        unread = facts.filter_map do |key, fact|
          key unless fact == READS || fact.any? { |callee, declared| declared && !facts.key?(callee) }
        end.to_set
        loop do
          reading = unread.select do |key|
            facts.fetch(key).any? { |callee, _| callee && facts.key?(callee) && !unread.include?(callee) }
          end
          break unread if reading.empty?

          unread.subtract(reading)
        end
      end

      def self.body_facts(typing, def_node)
        args, body = def_node.type == :defs ? def_node.children[2..3] : def_node.children[1..2]
        name = args&.children&.find { |arg| arg.type == :blockarg }&.children&.first
        handed = [] #: Array[[String?, bool]]
        reads = uses(body, nil, name) do |call|
          handed << handed_to(typing, call)
        end
        reads ? READS : handed
      end

      # Whether `node` reads the block named `name` other than by handing it
      # on; each call that hands it on is yielded.
      def self.uses(node, parent, name, &block)
        return false unless node.is_a?(::Parser::AST::Node)
        return false if NESTED.include?(node.type)

        case node.type
        when :yield then return true
        when :lvar then return node.children[0] == name && parent&.type != :block_pass
        end
        block.call(node) if hands_on?(node, parent, name)

        node.children.any? { |child| uses(child, node, name, &block) }
      end

      # A call passed the block with `&`, or a `super` that passes it as it
      # was given: with no `&` of its own and no block written at it.
      def self.hands_on?(node, parent, name)
        return false unless HANDED.include?(node.type)

        passes = node.children.select { |child| child.is_a?(::Parser::AST::Node) && child.type == :block_pass }
        return passes.any? { |pass| block_pass_of?(pass, name) } unless passes.empty?

        %i[super zsuper].include?(node.type) && !(parent&.type == :block && parent.children[0].equal?(node))
      end

      def self.block_pass_of?(node, name)
        node.is_a?(::Parser::AST::Node) && node.type == :block_pass &&
          (node.children[0].nil? || (node.children[0].type == :lvar && node.children[0].children[0] == name))
      end

      # `[callee_key, declared_reads]` for a call handed the block: the
      # project's method it may run, and whether a declaration of it lets the
      # block's return reach its own.
      def self.handed_to(typing, call)
        call = typing.explicit_super_of(node: call) || call if call.type == :zsuper
        method_call = typing.call_of(node: call)
        decls = method_call.respond_to?(:method_decls) ? method_call.method_decls.to_a : []
        [Specializations.method_key(decls), decls.any? { |decl| returns_block_value?(decl.method_type) }]
      rescue Typing::UnknownNodeError
        [nil, false]
      end

      # The call sites of a whole-file pass, held until every body they may
      # call has been read, and the bodies read so far.
      class Sites
        def initialize
          @facts = {} #: Hash[String, untyped]
          @sites = [] #: Array[[String, Arguments, bool]]
        end

        def read(typing, definitions) = @facts.merge!(BlockReads.facts(typing, definitions))

        def <<(site) = @sites << site

        def unread = @unread ||= BlockReads.unread(@facts)

        def tuples_of(key, arguments, harvested:) = Collector.tuples(key, arguments, harvested: harvested, unread: unread.include?(key))

        # `{ key => tuples }` of the sites, with each key no site fixes a
        # value of handed to `untupled`.
        def tuples(untupled:)
          @sites.each_with_object({}) do |(key, arguments, harvested), tuples| #$ Hash[String, Set[Arguments]]
            found = tuples_of(key, arguments, harvested: harvested)
            untupled.call(key) if found.empty?
            (tuples[key] ||= Set.new).merge(found)
          end
        end
      end

      def self.returns_block_value?(method_type)
        block = method_type.block or return false
        variables = method_type.type_params.map(&:name)
        returned = block.type.return_type.free_variables.to_a & variables
        !(returned & method_type.type.return_type.free_variables.to_a).empty?
      end
    end
  end
end

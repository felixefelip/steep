module Steep
  class Source
    # A file with every method body taken out but `defs` and the ones enclosing
    # them, so a check of it types those bodies and the class bodies around
    # them. The file-wide analyses stay the whole file's: a constant another
    # body appends to is not a value this file states.
    class OnlyDefs < Source
      def initialize(source, defs)
        @whole = source
        node = source.node or raise

        defs = Set[].compare_by_identity.merge(defs)
        kept = Set[].compare_by_identity
        each_enclosing_def(node, defs) { |def_node| kept << def_node }
        removed = [] #: Array[Range[Integer]]
        each_removed_def(node, kept) { |def_node| removed << (def_node.loc.line..def_node.loc.last_line) }

        annotations = source.mapping.values.flatten.reject do |annotation|
          annotation.line && removed.any? { |lines| lines.cover?(annotation.line) }
        end

        pruned = Source.delete_defs(node, kept)
        mapping = {} #: Hash[Parser::AST::Node, Array[AST::Annotation::t]]
        mapping.compare_by_identity
        Source.construct_mapping(node: pruned, annotations: annotations, mapping: mapping)
        annotations.each { |annotation| (mapping[pruned] ||= []) << annotation }

        super(buffer: source.buffer, path: source.path, node: pruned, mapping: mapping, comments: source.comments, ignores: source.ignores)
      end

      def accumulators = @whole.accumulators

      def constants = @whole.constants

      def local_assignments = @whole.local_assignments

      private

      def each_enclosing_def(node, defs, enclosing = [], &block)
        return unless node.is_a?(Parser::AST::Node)

        if node.type == :def || node.type == :defs
          enclosing += [node]
          enclosing.each(&block) if defs.include?(node)
        end
        node.children.each { |child| each_enclosing_def(child, defs, enclosing, &block) }
      end

      def each_removed_def(node, kept, &block)
        return unless node.is_a?(Parser::AST::Node)

        if node.type == :def || node.type == :defs
          return if kept.include?(node)
          return yield(node)
        end
        node.children.each { |child| each_removed_def(child, kept, &block) }
      end
    end
  end
end

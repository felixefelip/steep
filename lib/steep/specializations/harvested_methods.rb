module Steep
  module Specializations
    # The methods a specialized body defines with `define_method`, found where
    # its receiver, name and block are only known under a call's arguments:
    #
    #   def self.redefine(owner, name, value)
    #     redefine_method(owner.singleton_class, name) { value }
    #   end
    #
    #   def self.redefine_method(owner, name, &block)
    #     owner.define_method(name, &block)   # singleton_class(::Base), :__store, { value }
    #   end
    #
    # Each one is a body the run specializes like a `def`: its block, keyed by
    # the method it defines, and checked in place, in the frame that wrote it,
    # so the locals it closes over hold what they hold there
    # (`DefinedMethods.check`).
    class HarvestedMethods
      # What a run found defined, for the generator that declares it: a
      # method no signature names cannot be called, so nothing would ever
      # specialize it.
      #
      #     ---
      #     version: 1
      #     methods:
      #       Base.__class_attr_pluralize:
      #         params: "()"
      #         returns: untyped
      DEFAULT_OUTPUT_PATH = Pathname("sig/generated/.steep_defined_methods.yml").freeze
      SCHEMA_VERSION = 1

      def self.write(path, signatures)
        return path.delete if signatures.empty? && path.file?
        return if signatures.empty?

        path.parent.mkpath
        path.write(YAML.dump({ "version" => SCHEMA_VERSION, "methods" => signatures.sort.to_h }))
      end

      def initialize
        @pending = {} #: Hash[String, Set[Arguments]]
        @blocks = {} #: Hash[String, [String, Integer]]
        @enclosing = {} #: Hash[[String, Integer], Parser::AST::Node]
        @definitions = {} #: Hash[String, [Pathname, Parser::AST::Node]]
        @nodes = {} #: Hash[String, Parser::AST::Node]
      end

      # Whether `key` is a method a block defines. A check keys the block by
      # the method too, since one block may define several.
      def harvested?(key)
        @blocks.key?(key)
      end

      # Tuples for a method no body is known for yet, kept until one is.
      def remember(tuples, definitions)
        tuples.each { |key, arguments| (@pending[key] ||= Set.new).merge(arguments) unless definitions.key?(key) }
      end

      # Adds the definitions `outcomes` found to `definitions`, and the tuples
      # remembered for each to `tuples`.
      def adopt(outcomes, definitions, tuples, sources)
        @definitions = definitions
        outcomes.each_value do |outcome|
          outcome.defined.each do |key, block|
            next if definitions.key?(key)

            path = sources.keys.find { |candidate| candidate.to_s == block.loc.expression.source_buffer.name } or next
            definitions[key] = [path, block]
            @nodes[key] = block
            node_key = [path.to_s, block.loc.expression.begin_pos]
            @blocks[key] = node_key
            @enclosing[node_key] = enclosing_def(sources.fetch(path).node, block)
            (tuples[key] ||= Set.new).merge(@pending.delete(key) || [])
          end
        end
      end

      # `round` split so that a block is checked as one method at a time, and
      # never with the frame that wrote it specialized: the locals it closes
      # over hold what that frame holds under its declaration, not under
      # whichever of its call sites shares the check.
      def separate(round)
        rounds = [{}] #: Array[Hash[String, Arguments]]
        round.each do |key, arguments|
          target = rounds.find { |candidate| candidate.each_key.none? { |other| apart?(key, other) } }
          (target || (rounds << {}).last)[key] = arguments
        end
        rounds
      end

      # Each method found, with the parameters its block takes and what every
      # call of it returns (`declarations`, `CallSiteUnions`), or `untyped`
      # where that is not known.
      def signatures(declarations)
        @nodes.to_h do |key, block|
          [key, { "params" => "(#{block.children[1].children.filter_map { |param| param_rbs(param) }.join(", ")})", "returns" => declarations[key] || "untyped" }]
        end
      end

      # The `def` a pruned check keeps for a block it substitutes.
      def kept_def(node_key)
        @enclosing[node_key]
      end

      private

      PARAMS = {
        arg: "untyped %s", procarg0: "untyped %s", optarg: "?untyped %s", restarg: "*untyped %s",
        kwarg: "%s: untyped", kwoptarg: "?%s: untyped", kwrestarg: "**untyped %s"
      }.freeze

      def param_rbs(param)
        format = PARAMS[param.type] or return nil
        name = param.children[0]
        format.include?("untyped %s") && !name.is_a?(Symbol) ? format.sub(" %s", "") : format % name
      end

      def apart?(key, other)
        block = @blocks[key]
        other_block = @blocks[other]
        return true if block && block == other_block

        writes?(block, other) || writes?(other_block, key)
      end

      def writes?(block, key)
        block && @definitions[key]&.last.equal?(@enclosing[block])
      end

      def enclosing_def(node, block, enclosing = nil)
        return nil unless node.is_a?(Parser::AST::Node)
        return enclosing if node.equal?(block)

        enclosing = node if node.type == :def || node.type == :defs
        node.children.each do |child|
          found = enclosing_def(child, block, enclosing) and return found
        end
        nil
      end
    end
  end
end

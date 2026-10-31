module Steep
  module Specializations
    # The methods a call site defines with `define_method`, found by following
    # it through the frames it runs, where the receiver, name and block are
    # only known under each frame's arguments:
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
      #         block: lib/class_attribute.rb:12:8
      #
      # `block` is the block that is the method's body, which an ordinary
      # check then reads as that method (`DefinedMethods.check`).
      DEFAULT_OUTPUT_PATH = Pathname("sig/generated/.steep_defined_methods.yml").freeze
      SCHEMA_VERSION = 1

      def self.write(path, signatures)
        return path.delete if signatures.empty? && path.file?
        return if signatures.empty?

        path.parent.mkpath
        path.write(YAML.dump({ "version" => SCHEMA_VERSION, "methods" => signatures.sort.to_h }))
      end

      # `{ site => [method key] }` for the blocks a run found to be method
      # bodies, as `Store#body_methods` reads them.
      def self.bodies(base_dir)
        path = base_dir + DEFAULT_OUTPUT_PATH
        return {} unless path.file?

        methods = YAML.safe_load(path.read)&.fetch("methods", nil)
        return {} unless methods.is_a?(Hash)

        methods.each_with_object({}) do |(key, signature), result| #$ Hash[String, Array[String]]
          block = signature.is_a?(Hash) && signature["block"]
          (result[File.expand_path(block, base_dir.to_s)] ||= []) << key if block.is_a?(String)
        end.transform_values(&:sort)
      rescue Psych::Exception
        {}
      end

      def initialize(base_dir)
        @base_dir = base_dir
        @pending = {} #: Hash[String, Set[Arguments]]
        @blocks = {} #: Hash[String, [String, Integer]]
        @enclosing = {} #: Hash[[String, Integer], Parser::AST::Node]
        @definitions = {} #: Hash[String, [Pathname, Parser::AST::Node]]
        @nodes = {} #: Hash[String, Parser::AST::Node]
      end

      # The methods each adopted block is the body of, by the block's site.
      def bodies
        @nodes.each_with_object({}) do |(key, block), result| #$ Hash[String, Array[String]]
          (result[site(block)] ||= []) << key
        end.transform_values(&:sort)
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

      # Adds the methods `found` (`key => block`) to `definitions`, and the
      # tuples remembered for each to `tuples`.
      def adopt(found, definitions, tuples, sources)
        @definitions = definitions
        found.each do |key, block|
          next if definitions.key?(key)

          path = sources.keys.find { |candidate| candidate.to_s == block.loc.expression.source_buffer.name } or next
          definitions[key] = [path, block]
          @nodes[key] = block
          node_key = [path.to_s, block.loc.expression.begin_pos]
          @blocks[key] = node_key
          @enclosing[node_key] = Collector.enclosing(Collector.definitions(sources.fetch(path)).to_a, block)&.last
          (tuples[key] ||= Set.new).merge(@pending.delete(key) || [])
        end
        self
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
          params = "(#{block.children[1].children.filter_map { |param| param_rbs(param) }.join(", ")})"
          [key, { "params" => params, "returns" => declarations[key] || "untyped", "block" => relative_site(block) }]
        end
      end

      # The methods the call sites of a method that defines one (`definers`)
      # define there, as `key => block`, read by following each call through
      # the frames it runs, the way the eval harvest reads what it writes: only
      # what a call site runs for certain defines a method, and a block's body
      # is deferred. `check` types the bodies `{ key => arguments }` names.
      def harvest(locations, definitions, definers, overrides:, rounds:, check:)
        found = {} #: Hash[String, Parser::AST::Node]
        defining = locations.filter_map do |key, by_arguments|
          handed = by_arguments.reject { |arguments, _| arguments.hands_self? }
          [key, handed] if definitions.key?(key) && definers.include?(key) && !handed.empty?
        end.to_h
        rounds.call(defining.transform_values { |by_arguments| by_arguments.keys.to_set }).each do |active|
          typings = check.call(active)
          active.each do |key, arguments|
            path, def_node = definitions.fetch(key)
            typing = typings[path] or next

            walk = Walk.new(definitions, definers, overrides, check)
            walk.defined_in(typing, def_node, arguments, Set[key], found)
          end
        end
        found
      end

      Walk = Struct.new(:definitions, :definers, :overrides, :check) do
        def defined_in(typing, def_node, arguments, reading, found)
          Evals.effects(typing, def_node, definers, overrides: overrides, defines: true).each do |effect|
            next unless effect.certain

            if effect.kind == :define
              key, block = DefinedMethods.definition(typing, effect.node, def_node, arguments)
              found[key] ||= block if key
            elsif effect.kind == :frame && !reading.include?(effect.callee)
              entered(typing, effect, reading, found)
            end
          end
        end

        def entered(typing, effect, reading, found)
          path, callee_node = definitions[effect.callee]
          return unless path
          callee = Arguments.recorded(effect.node, typing) or return
          frame_self = typing.self_type_of_call(node: effect.node) or return
          callee = callee.resolve_self(frame_self)
          callee = callee.with_self(frame_self) if Evals.on_self?(effect.node.type == :block ? effect.node.children[0] : effect.node)
          inner = check.call({ effect.callee => callee })[path] or return
          defined_in(inner, callee_node, callee, reading | [effect.callee], found)
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

      def site(block)
        expression = block.loc.expression
        "#{File.expand_path(expression.source_buffer.name)}:#{expression.line}:#{expression.column}"
      end

      def relative_site(block)
        Pathname(site(block)).relative_path_from(Pathname(@base_dir).expand_path).to_s
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
    end
  end
end

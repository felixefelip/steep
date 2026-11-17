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
        @frames = {} #: Hash[String, [String, Arguments]?]
        @rounds = Kept.new
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

      # The methods that define methods once the blocks found are bodies too:
      # a found block that calls one of `definers`, and a method calling it.
      def definers(definers)
        grown = definers.dup
        loop do
          added = @definitions.filter_map { |key, (_, body)| key if !grown.include?(key) && Evals.writes_code?(body, grown, defines: true) }
          return grown - definers if added.empty?

          grown.merge(added)
        end
      end

      # `round` split so that a block is checked as one method at a time, with
      # the frame that wrote it checked under the arguments of the call that
      # defined the method: the locals it closes over hold what they hold in
      # that call. Where calls under different arguments define the method, the
      # frame is checked under its declaration.
      def separate(round)
        rounds = [{}] #: Array[Hash[String, Arguments]]
        round.each do |key, arguments|
          entries = { key => arguments }.merge(@frames[key].then { |frame| frame ? [frame].to_h : {} })
          target = rounds.find { |candidate| fits?(candidate, entries) }
          (target || (rounds << {}).last).merge!(entries)
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
      # is deferred. `check` types, under a store, the bodies
      # `{ key => arguments }` names. A round is checked again only where
      # `store` answers what it asked differently from when it was last checked.
      def harvest(locations, definitions, definers, overrides:, rounds:, check:, store:, class_exits:)
        found = {} #: Hash[String, Parser::AST::Node]
        frames = {} #: Hash[String, Set[[String, Arguments]]]
        defining = locations.filter_map do |key, by_arguments|
          handed = by_arguments.reject { |arguments, _| arguments.hands_self? }
          [key, handed] if definitions.key?(key) && definers.include?(key) && !handed.empty?
        end.to_h
        rounds.call(defining.transform_values { |by_arguments| by_arguments.keys.to_set }).each do |active|
          defined = @rounds.value([active, definitions.size], store, class_exits) do |logged, left|
            checked = ->(substituted) { check.call(logged, substituted).tap { |typings| left.concat(typings.values.compact.map(&:class_exits)) } }
            defined_in_round(active, definitions, Walk.new(definitions, definers, overrides, checked, @frames), checked.call(active))
          end
          defined.each do |key, (block, writers)|
            found[key] ||= block
            (frames[key] ||= Set[]).merge(writers)
          end
        end
        frames.each { |key, writers| @frames[key] = writers.size == 1 ? writers.first : nil }
        found
      end

      # `{ key => [block, writers] }` for the methods `active`'s bodies define,
      # each with the calls that wrote its block (`Walk#record`).
      def defined_in_round(active, definitions, walk, typings)
        found = {} #: Hash[String, [Parser::AST::Node, Set[[String, Arguments]]]]
        active.each do |key, arguments|
          path, def_node = definitions.fetch(key)
          typing = typings[path] or next

          walk.defined_in(typing, def_node, arguments, [[key, def_node, arguments]], found)
        end
        found
      end

      # `chain` is the frames the walk entered, outermost first, as
      # `[key, def_node, arguments]`; the one whose `def` holds a defined block
      # is the call that wrote it.
      Walk = Struct.new(:definitions, :definers, :overrides, :check, :frames) do
        def defined_in(typing, def_node, arguments, chain, found)
          Evals.effects(typing, def_node, definers, overrides: overrides, defines: true, defined: definitions.method(:key?)).each do |effect|
            next unless effect.certain

            if effect.kind == :define
              key, block = DefinedMethods.definition(effect.typing, effect.node, def_node, arguments)
              record(found, key, block, chain) if key
            elsif effect.kind == :frame && chain.none? { |entered, _, _| entered == effect.callee }
              entered(effect.typing, effect, chain, found)
            end
          end
        end

        def record(found, key, block, chain)
          block_node, writers = found[key] ||= [block, Set[]]
          return unless block_node.equal?(block)

          writer = chain.reverse.find { |_, frame_def, _| holds?(frame_def, block) }
          writers << [writer[0], writer[2]] if writer
        end

        def holds?(frame_def, block)
          frame_range = frame_def.loc.expression
          block_range = block.loc.expression
          frame_range.source_buffer.name == block_range.source_buffer.name && frame_range.begin_pos <= block_range.begin_pos && block_range.end_pos <= frame_range.end_pos
        end

        def entered(typing, effect, chain, found)
          path, callee_node = definitions[effect.callee]
          return unless path
          callee = Arguments.recorded(effect.node, typing) or return
          frame_self = typing.self_type_of_call(node: effect.node) or return
          callee = callee.resolve_self(frame_self)
          callee = callee.with_self(frame_self) if Evals.on_self?(effect.node.type == :block ? effect.node.children[0] : effect.node)
          inner = check.call({ effect.callee => callee }.merge(frames[effect.callee].then { |frame| frame ? [frame].to_h : {} }))[path] or return
          defined_in(inner, callee_node, callee, chain + [[effect.callee, callee_node, callee]], found)
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

      # Whether `entries` (a method and the frame that wrote its block) can be
      # checked in `round`: a key in both under the same arguments, and no two
      # keys apart unless one is the other's frame under its call's arguments.
      def fits?(round, entries)
        merged = round.merge(entries)
        entries.all? do |key, arguments|
          round.all? do |other, other_arguments|
            next other_arguments == arguments if other == key

            !apart?(key, other) || framed?(key, other, merged) || framed?(other, key, merged)
          end
        end
      end

      def framed?(key, frame, round)
        @frames[key] == [frame, round[frame]]
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

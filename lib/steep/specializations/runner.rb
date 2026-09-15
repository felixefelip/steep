module Steep
  module Specializations
    # Drives specialization inference across a project, in the two passes
    # `Steep::Postconditions::Runner` established for a sidecar:
    #
    #   1. Type-check every source under its declarations, recording what each
    #      method's body evaluates to and which argument tuples the call sites
    #      supply.
    #   2. Re-check the bodies that have a tuple, with the tuple substituted for
    #      the declared parameter types, and keep the returns that differ from
    #      pass 1.
    #
    # Those two carry a literal across ONE call. A chain needs them iterated:
    # each generation re-checks under what the last one found, both at the
    # parameters it substitutes and at the sends inside the body, until the
    # returns stop changing (felixefelip/rbs_infer#345, stage S5).
    #
    # Iterating over literals does not terminate by itself, and it diverges on
    # both sides of a specialization:
    #
    #   def g(s) = g("#{s}x")          # a longer ARGUMENT every generation
    #   def f(flag) = "#{f(flag)}x"    # a longer RETURN, on one fixed tuple
    #
    # Widening answers both: a literal rises to the class it instantiates, which
    # is what a program that does not fix a value does fix. A tuple a later
    # generation discovers widens past `WIDEN_AFTER` generations or past
    # `LITERAL_WIDTH` characters, and a tuple fixing no value specializes
    # nothing. A return widens as soon as it DISAGREES with the generation
    # before, because one that keeps moving is not converging on a value.
    #
    # Widening is remembered per entry, so each side of one is bounded — a tuple
    # set that stops growing, a return that widens once and stays widened — and
    # the loop runs until nothing changes rather than until a generation count is
    # spent.
    class Runner
      DEFAULT_OUTPUT_PATH = Pathname("sig/generated/.steep_specializations.yml").freeze

      # Generations whose newly discovered tuples are still taken literally. Past
      # it every new tuple widens, so a body that folds a longer literal each
      # time cannot keep feeding itself.
      WIDEN_AFTER = 3

      # A tuple whose spelling grows past this is folding rather than fixing, so
      # it widens whatever the generation.
      LITERAL_WIDTH = 64

      class TargetContext
        attr_reader :subtyping, :constant_resolver, :sources

        def initialize(subtyping:, constant_resolver:, sources:)
          @subtyping = subtyping
          @constant_resolver = constant_resolver
          @sources = sources
        end
      end

      def self.run(project)
        new(project).run
      end

      def initialize(project)
        @project = project
        @evals = {} #: Hash[String, Array[String?]]
      end

      # What each call site of a code-writing method defines there, by
      # `path:line:column`. Filled by `run` alongside the return types.
      attr_reader :evals

      def run
        methods = {} #: Hash[String, Hash[String, String]]
        @evals = {}
        @project.targets.each { |target| specialize_target(target, methods) }
        methods
      end

      def output_path
        @project.absolute_path(DEFAULT_OUTPUT_PATH)
      end

      def evals_output_path
        @project.absolute_path(Evals::DEFAULT_OUTPUT_PATH)
      end

      def write(methods)
        if methods.empty?
          output_path.delete if output_path.file?
        else
          Writer.write(output_path, methods)
        end

        if @evals.empty?
          evals_output_path.delete if evals_output_path.file?
        else
          Evals::Writer.write(evals_output_path, @evals)
        end
      end

      private

      def specialize_target(target, methods)
        context = load_target(target) or return

        parameter_writers = eval_parameters(context)
        writers = code_writers(context, parameter_writers)
        locations = {} #: Hash[String, Hash[Arguments, Set[String]]]
        baselines, tuples, definitions, callees = collect(context, Store.empty, locations, writers)
        if tuples.empty?
          # No return specializes, but a body that writes code can still be
          # decided — by its defaults, or by having no arguments at all.
          harvest_evals(context, Store.empty, locations, definitions, parameter_writers)
          return
        end

        found = {} #: Hash[String, Hash[String, AST::Types::t]]
        widened = Set[] #: Set[[String, String]]
        seen = Set[] #: Set[Hash[String, Hash[String, AST::Types::t]]]
        generation = 0

        loop do
          discovered, revealed = specialize(context, store(found), baselines, tuples, definitions)
          discovered = settle(found, discovered, baselines, widened)
          grown = grow(tuples, revealed, generation)
          # Both have to settle, not just the returns: a generation that finds no
          # new return can still fix a tuple inside a body it re-checked, and that
          # tuple is what the next generation specializes.
          break if discovered == found && grown == tuples
          # A state seen before cannot lead anywhere a later generation has not
          # already been. Widening bounds an entry's literals; this bounds the one
          # shape it says nothing about — a return alternating between two
          # CLASSES, which no amount of widening settles.
          break unless seen.add?(discovered)

          paths = affected_paths(callees, changed_keys(found, discovered))
          found = discovered
          tuples = grow(grown, call_sites(context, store(found), definitions, paths, locations, writers), generation)
          generation += 1
        end

        found.each do |key, entries|
          (methods[key] ||= {}).merge!(entries.transform_values(&:to_s))
        end

        harvest_evals(context, store(found), locations, definitions, parameter_writers)
      end

      # `discovered` with every entry that disagrees with the generation before
      # widened, and every entry widening took back to what the declaration
      # already answers dropped. An entry written for the first time is left as
      # found: a body just reached is converging, not oscillating.
      #
      # `widened` remembers which entries have widened, and that memory is what
      # makes the loop terminate rather than cycle. Widening only by comparison
      # with the generation before forgets: a widened entry that the next
      # generation drops comes back literal, and the result then depends on which
      # generation the loop happens to stop at.
      def settle(found, discovered, baselines, widened)
        discovered.each_with_object({}) do |(key, entries), result|
          settled = entries.filter_map do |tuple, type|
            previous = found.dig(key, tuple)
            if widened.include?([key, tuple]) || (previous && previous != type)
              widened << [key, tuple]
              type = Specializations.widen_literals(type)
            end

            [tuple, type] unless type.to_s == baselines[key]
          end.to_h

          result[key] = settled unless settled.empty?
        end
      end

      # The returns every known tuple produces, read under `store` — the
      # generation before's findings, or nothing at all in the first one — plus
      # the tuples those same bodies supply once their parameters hold the tuple.
      # `relay(loud)` forwarding to `label(loud)` fixes `label(true)` only here,
      # where `loud` is `true`; a sweep that substitutes nothing cannot see it.
      def specialize(context, store, baselines, tuples, definitions)
        found = {} #: Hash[String, Hash[String, AST::Types::t]]
        revealed = {} #: Hash[String, Set[Arguments]]

        rounds(tuples).each do |active|
          typings = check_definitions(context, store, active, definitions)

          active.each do |key, arguments|
            path, def_node = definitions.fetch(key)
            type = body_type(typings[path], def_node) or next
            next if type.to_s == baselines[key]

            (found[key] ||= {})[arguments.key] = type
          end

          typings.each_value do |typing|
            next unless typing

            Collector.call_sites(typing).each do |key, arguments|
              (revealed[key] ||= Set.new).merge(arguments) if definitions.key?(key)
            end
          end
        end

        [found, revealed]
      end

      # What each call site of a code-writing method writes there, read off one
      # last check of the body under that call's arguments. Separate from the
      # loop above, and after it: a generation is a guess at the returns, and a
      # body rendered from a guess would be rendered again, differently, by the
      # next one.
      #
      # Rounds, like `specialize`: two macros in one file are read by one check,
      # and only two tuples of the SAME macro cost two.
      def harvest_evals(context, store, locations, definitions, parameter_writers)
        writing = locations.select { |key, _| definitions.key?(key) }
        return if writing.empty?

        defaults = writing.keys.to_h { |key| [key, Collector.defaults(definitions.fetch(key)[1])] }

        rounds(writing.transform_values { |by_arguments| by_arguments.keys.to_set }).each do |active|
          typings = check_definitions(context, store, with_defaults(active, defaults), definitions)

          active.each do |key, arguments|
            path, def_node = definitions.fetch(key)
            typing = typings[path] or next

            sources = eval_sources(context, store, typing, def_node, definitions, parameter_writers)
            next if sources.empty?

            writing.fetch(key).fetch(arguments).each { |site| @evals[site] = sources }
          end
        end
      end

      # What this body writes, in the order it writes it: its own evals, and what
      # the methods it hands its own `self` to write there. A macro that evals
      # once and then hands off produces both, and the class gets them in source
      # order — the order the consumer places them in.
      def eval_sources(context, store, typing, def_node, definitions, parameter_writers)
        Evals.effects(typing, def_node, parameter_writers).flat_map do |effect|
          if effect.kind == :eval
            [Evals.chunk_of(typing, effect)]
          elsif effect.certain
            delegated_sources(context, store, typing, effect, definitions)
          else
            # Code is written here and this call site does not decide what: a
            # hole, the same answer an eval it cannot fold gets.
            [nil]
          end
        end
      end

      # What the method this one hands its own `self` to writes there, read under
      # the arguments THIS call passes it.
      #
      #   def has_rich_text(name)
      #     Writer.generate(self, name)      # ← the call read here
      #   end
      #
      # The frame in between is what the answer belongs to: `generate` evals on
      # an object it was handed, so its own call site — one line inside a gem —
      # is the wrong place to attribute anything to, while `has_rich_text`'s call
      # sites are written in the classes that actually get the methods.
      #
      # The inner body is read with ONE receiver allowed: the parameter this call
      # was seen to hand its self to. A helper evaling on two parameters writes
      # for two different objects, and only one of them is the class being
      # attributed to.
      #
      # One frame, deliberately. Two would need the argument threaded through a
      # chain, and nothing yet asks for it.
      def delegated_sources(context, store, typing, effect, definitions)
        entry = definitions[effect.callee] or return [nil]
        path, callee_node = entry
        arguments = Specializations::Arguments.from_send(effect.node, typing) or return [nil]
        receiver = Evals.parameter_names(callee_node)[effect.index] or return [nil]

        positionals, keywords = Collector.defaults(callee_node)
        arguments = arguments.with_defaults(positionals: positionals, keywords: keywords)

        inner = check_definitions(context, store, { effect.callee => arguments }, definitions)
        inner_typing = inner[path] or return [nil]

        Evals.sources(inner_typing, callee_node, [receiver])
      end

      # The methods that eval on a PARAMETER, by the position it sits in. Not
      # writers themselves — they write on an object they were handed, so their
      # own call site is the wrong place to attribute anything to — but what a
      # frame handing its own `self` is recognised against.
      def eval_parameters(context)
        writers = {} #: Hash[String, Set[Integer]]

        context.sources.each_value do |source|
          Collector.definitions(source).each do |key, def_node|
            indices = Evals.eval_parameters(def_node)
            writers[key] = indices unless indices.empty?
          end
        end

        writers
      end

      # A call omitting an optional parameter does not leave it open: the body
      # runs with the definition's default, and which chunk the macro writes can
      # turn on exactly that.
      def with_defaults(active, defaults)
        active.to_h do |key, arguments|
          positionals, keywords = defaults.fetch(key)

          [key, arguments.with_defaults(positionals: positionals, keywords: keywords)]
        end
      end

      # The tuples for the next generation: the ones already known, plus the ones
      # the returns just discovered revealed — a call whose argument is now a
      # literal because the call inside it specialized. Each new tuple is kept
      # only while it is not widened.
      def grow(tuples, collected, generation)
        grown = tuples.transform_values(&:dup)

        collected.each do |key, arguments_set|
          arguments_set.each do |arguments|
            next if tuples[key]&.include?(arguments)
            next if widened?(arguments, generation)

            (grown[key] ||= Set.new) << arguments
          end
        end

        grown
      end

      # Whether this tuple's literals rise to their classes instead of fixing a
      # value. Widening one and dropping it are the same thing here: a tuple that
      # fixes nothing records the declaration back.
      def widened?(arguments, generation)
        generation >= WIDEN_AFTER || arguments.key.length > LITERAL_WIDTH
      end

      def store(methods)
        Store.new(methods: methods.transform_values { |entries| entries.transform_values(&:to_s) }, source: nil)
      end

      # The argument tuples the call sites in `paths` supply when read under
      # `store`. Separate from `collect`, which also needs each body's type and so
      # keeps its own single sweep.
      # The methods that define methods by evaluating a string, which is the
      # only thing the eval harvest reads. A pure walk of trees already parsed,
      # so a project without the idiom pays this and nothing else.
      def code_writers(context, parameter_writers)
        writers = Set[] #: Set[String]

        context.sources.each_value do |source|
          Collector.definitions(source).each do |key, def_node|
            writers << key if Evals.writes_code?(def_node, parameter_writers)
          end
        end

        writers
      end

      def call_sites(context, store, definitions, paths, locations, writers)
        tuples = {} #: Hash[String, Set[Arguments]]

        paths.each do |path|
          source = context.sources[path] or next
          typing = type_check(context, store, source, {})

          Collector.each_call_site(typing) do |key, arguments, node|
            next unless definitions.key?(key)

            (tuples[key] ||= Set.new) << arguments if arguments.literal?
            record_location(locations, key, arguments, path, node) if writers.include?(key)
          end
        end

        tuples
      end

      def record_location(locations, key, arguments, path, node)
        expression = node.loc.expression or return
        site = "#{@project.relative_path(path)}:#{expression.line}:#{expression.column}"

        ((locations[key] ||= {})[arguments] ||= Set.new) << site
      end

      # The methods whose entries this generation changed.
      def changed_keys(before, after)
        (before.keys | after.keys).select { |key| before[key] != after[key] }.to_set
      end

      # Only a file that calls one of `keys` can spell a tuple it did not spell
      # before: a call's argument types change when what the call inside it
      # returns changes, and nothing else here moves.
      def affected_paths(callees, keys)
        return [] if keys.empty?

        callees.select { |_, called| called.intersect?(keys) }.keys
      end

      def load_target(target)
        loader = Project::Target.construct_env_loader(options: target.options, project: @project)
        file_loader = Services::FileLoader.new(base_dir: @project.base_dir)

        file_loader.each_path_in_patterns(target.signature_pattern) do |path|
          absolute = @project.absolute_path(path)
          loader.add(path: absolute) if absolute.file?
        end

        status = Services::SignatureService.load_from(loader, implicitly_returns_nil: target.implicitly_returns_nil).status
        return nil unless status.is_a?(Services::SignatureService::LoadedStatus)

        sources = {} #: Hash[Pathname, Source]
        file_loader.each_path_in_patterns(target.source_pattern) do |path|
          absolute = @project.absolute_path(path)
          next unless absolute.file? && absolute.extname == ".rb"

          begin
            sources[absolute] = Source.parse(absolute.read, path: absolute, factory: status.subtyping.factory)
          rescue ::Parser::SyntaxError, AnnotationParser::SyntaxError
            next
          end
        end

        TargetContext.new(subtyping: status.subtyping, constant_resolver: status.constant_resolver, sources: sources)
      end

      def collect(context, store, locations, writers)
        baselines = {} #: Hash[String, String]
        tuples = {} #: Hash[String, Set[Arguments]]
        definitions = {} #: Hash[String, [Pathname, Parser::AST::Node]]
        callees = {} #: Hash[Pathname, Set[String]]

        context.sources.each do |path, source|
          typing = type_check(context, store, source, {})

          Collector.definitions(source).each do |key, def_node|
            definitions[key] = [path, def_node]
            type = body_type(typing, def_node)
            baselines[key] = type.to_s if type
          end

          Collector.each_call_site(typing) do |key, arguments, node|
            (tuples[key] ||= Set.new) << arguments if arguments.literal?
            record_location(locations, key, arguments, path, node) if writers.include?(key)
          end

          callees[path] = Collector.callees(typing) if typing
        end

        tuples.select! { |key, _| definitions.key?(key) }
        locations.select! { |key, _| definitions.key?(key) }
        [baselines, tuples, definitions, callees]
      end

      # One round per tuple position, so a method with two tuples costs two
      # re-checks and a file holding several specialized methods still costs one
      # check per round — the tuples of different methods do not interact.
      def rounds(tuples)
        lists = tuples.transform_values(&:to_a)
        depth = lists.each_value.map(&:size).max || 0

        (0...depth).map do |index|
          lists.filter_map { |key, list| [key, list[index]] if list[index] }.to_h
        end
      end

      def check_definitions(context, store, active, definitions)
        paths = active.keys.filter_map { |key| definitions[key]&.first }.uniq
        by_node = active.to_h do |key, arguments|
          path, def_node = definitions.fetch(key)
          [node_key(path, def_node), arguments]
        end

        paths.to_h do |path|
          [path, type_check(context, store, context.sources.fetch(path), by_node)]
        end
      end

      # What the checker matches a body by, since the name it would derive from
      # the self type is not always the name this pass keys the body under.
      def node_key(path, def_node)
        [path.to_s, def_node.loc.expression.begin_pos]
      end

      # `store` is always one this run computed, never the sidecar on disk:
      # reading what it is about to overwrite would make every run one more
      # generation of a fixpoint whose bound is per-run.
      def type_check(context, store, source, active)
        Services::TypeCheckService.type_check(
          source: source,
          subtyping: context.subtyping,
          constant_resolver: context.constant_resolver,
          cursor: nil,
          contracts: @project.contracts,
          postconditions: @project.postconditions,
          callbacks: @project.callbacks,
          specializations: store.with_active(active),
          literal_method_registry: @project.literal_method_registry,
          delegation_registry: @project.delegation_registry,
          constructor_bindings: @project.constructor_binding_registry,
          return_forwarding: @project.return_forwarding_registry,
          return_alias: @project.return_alias_registry
        )
      end

      def body_type(typing, def_node)
        return nil unless typing

        body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
        return nil unless body && typing.has_type?(body)

        type = typing.type_of(node: body)
        return nil if type.is_a?(AST::Types::Any) || type.is_a?(AST::Types::Bot)

        type
      end
    end
  end
end

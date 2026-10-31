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
    # generation discovers widens once its method has already been handed new
    # tuples in `WIDEN_AFTER` generations, or where one of its arguments is past
    # `LITERAL_WIDTH` characters, and a tuple fixing no value specializes
    # nothing. A return widens as soon as it DISAGREES
    # with the generation before, because one that keeps moving is not
    # converging on a value — unless it only refines it (`Specializations.refines?`),
    # which an entry may do in `WIDEN_AFTER` generations.
    #
    # Widening is remembered per entry, so each side of one is bounded — a tuple
    # set that stops growing, a return that widens once and stays widened — and
    # the loop runs until nothing changes rather than until a generation count is
    # spent.
    class Runner
      DEFAULT_OUTPUT_PATH = Pathname("sig/generated/.steep_specializations.yml").freeze

      # Generations in which one method's newly discovered tuples are still
      # taken literally. Past it that method's new tuples widen, so a body that
      # folds a longer literal each time cannot keep feeding itself.
      WIDEN_AFTER = 3

      # An argument whose spelling grows past this is folding rather than
      # fixing, so its tuple widens whatever the generation.
      LITERAL_WIDTH = 64

      STATE_WIDTH = 1024

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
        @exits = {} #: Hash[String, Hash[String, ObjectStates::Exit]]
        @demand = nil
        @demanding = Set[] #: Set[[String, String]]
        @class_exits = {} #: Hash[RBS::TypeName, Hash[Symbol, AST::Types::t]]
        @declarations = {} #: Hash[String, String]
        @defined_methods = {} #: Hash[String, Hash[String, String]]
        @overrides = nil
        @receivers = {} #: Hash[String, Array[String]]
        @unknown_receivers = Set[] #: Set[String]
        @pruned = {} #: Hash[[Pathname, Array[Integer]], Source]
      end

      # What each call site of a code-writing method defines there, by
      # `path:line:column`. Filled by `run` alongside the return types.
      attr_reader :evals

      # What each method returns across all its calls (`CallSiteUnions`), by
      # method. Filled by `run`.
      attr_reader :declarations

      # The classes each typed receiver of a reader may be (`Receivers`), by
      # site, and the methods found defined with `define_method`
      # (`HarvestedMethods#signatures`). Filled by `run`.
      attr_reader :receivers, :defined_methods

      def run
        methods = {} #: Hash[String, Hash[String, String]]
        @evals = {}
        @exits = {}
        @class_exits = {}
        @declarations = {}
        @defined_methods = {}
        @receivers = {}
        @unknown_receivers = Set[]
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
        exits = @exits.transform_values { |by_key| by_key.transform_values { |exit| Specializations.sidecar_exit(exit) } }.reject { |_, by_key| by_key.empty? }
        if methods.empty? && @declarations.empty? && @receivers.empty? && exits.empty?
          output_path.delete if output_path.file?
        else
          Writer.write(output_path, methods, @declarations, @receivers.transform_keys { |site| @project.relative_path(Pathname(site)).to_s }, exits)
        end

        if @evals.empty?
          evals_output_path.delete if evals_output_path.file?
        else
          Evals::Writer.write(evals_output_path, @evals)
        end
        HarvestedMethods.write(@project.absolute_path(HarvestedMethods::DEFAULT_OUTPUT_PATH), @defined_methods)
      end

      private

      def specialize_target(target, methods)
        context = load_target(target) or return

        writers = code_writers(context)
        @definers = code_writers(context, defines: true)
        @factory = context.subtyping.factory
        @overrides = Overrides.new(checker: context.subtyping, registry: @project.constructor_binding_registry)
        @checks = Checks.new(overrides: @overrides, returned: method(:returned_type))
        @harvested = HarvestedMethods.new(@project.base_dir)
        definitions = {} #: Hash[String, [Pathname, Parser::AST::Node]]
        @growth = {} #: Hash[String, Set[Integer]]
        @refinements = Hash.new(0) #: Hash[[String, String], Integer]
        demanded = {} #: Hash[[String, String], ObjectStates::Exit?]
        @demand = ->(store, key, arguments, in_checked_body) { demand_exit(context, definitions, demanded, store, key, arguments, in_checked_body) }
        locations = {} #: Hash[String, Hash[Arguments, Set[String]]]
        baselines, tuples, collected, callees = collect(context, Store.new(methods: {}, source: nil, receivers: @receivers, bodies: {}), locations, writers | @definers)
        definitions.merge!(collected)
        if tuples.empty?
          # No return specializes, but a body that writes code can still be
          # decided — by its defaults, or by having no arguments at all.
          empty = Store.new(methods: {}, source: nil, receivers: @receivers, bodies: {})
          @defined_methods.merge!(@harvested.adopt(harvest_defines(context, empty, locations, definitions), definitions, {}, context.sources).signatures({}))
          harvest_evals(context, empty, locations, definitions, writers)
          return
        end

        found = {} #: Hash[String, Hash[String, AST::Types::t]]
        widened = Set[] #: Set[[String, String]]
        seen = Set[] #: Set[[Hash[String, Hash[String, AST::Types::t]], Hash[String, Set[Arguments]], Hash[String, Hash[String, ObjectStates::Exit]], Hash[RBS::TypeName, Hash[Symbol, AST::Types::t]]]]
        generation = 0

        loop do
          demanded.clear
          exits = @exits.transform_values(&:dup)
          class_exits = @class_exits.dup
          discovered, revealed = specialize(context, store(found), baselines, tuples, definitions)
          @harvested.adopt(harvest_defines(context, store(found), locations, definitions), definitions, revealed, context.sources)
          discovered = settle(found, discovered, baselines, widened)
          grown = grow(tuples, revealed, generation)
          # Both have to settle, not just the returns: a generation that finds no
          # new return can still fix a tuple inside a body it re-checked, and that
          # tuple is what the next generation specializes. So do the exits, which
          # the caller one frame out reads only in the generation after.
          break if discovered == found && grown == tuples && @exits == exits && @class_exits == class_exits
          # A state seen before cannot lead anywhere a later generation has not
          # already been. Widening bounds an entry's literals; this bounds the one
          # shape it says nothing about — a return alternating between two
          # CLASSES, which no amount of widening settles.
          break unless seen.add?([discovered, grown, @exits.transform_values(&:dup), @class_exits.dup])

          paths = affected_paths(callees, changed_keys(found, discovered) | changed_keys(exits, @exits))
          found = discovered
          demanded.clear
          tuples = grow(grown, call_sites(context, store(found), definitions, paths, locations, writers | @definers), generation)
          generation += 1
        end

        found.each do |key, entries|
          writable = entries.select { |argument_key, _| Arguments.persistable_key?(argument_key) }
          (methods[key] ||= {}).merge!(writable.transform_values { |type| Specializations.sidecar_value(Specializations.sidecar_writable(type)) }) unless writable.empty?
        end
        @declarations.merge!(call_site_unions(context, store(found), found, baselines, callees, definitions))
        @defined_methods.merge!(@harvested.signatures(@declarations))

        harvest_evals(context, store(found), locations, definitions, writers)
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
            if widened.include?([key, tuple]) || (previous && previous != type && !refinement?(key, tuple, type, previous))
              widened << [key, tuple]
              type = Specializations.widen_literals(type)
            end

            [tuple, type] unless type.to_s == baselines[key]
          end.to_h

          result[key] = settled unless settled.empty?
        end
      end

      def refinement?(key, tuple, type, previous)
        return false unless Specializations.refines?(type, previous)

        (@refinements[[key, tuple]] += 1) <= WIDEN_AFTER
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
          outcomes = specialized_checks(context, store, active, definitions)

          active.each do |key, arguments|
            outcome = outcomes.fetch(definitions.fetch(key).first)
            store_exit(key, arguments, outcome.exits[key]) if outcome.exits.key?(key)
            type = outcome.returns[key] or next
            next if type.to_s == baselines[key]

            (found[key] ||= {})[arguments.key] = type
          end

          outcomes.each_value do |outcome|
            @harvested.remember(outcome.sites, definitions)
            outcome.sites.each { |key, arguments| (revealed[key] ||= Set.new).merge(arguments) if definitions.key?(key) }
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
      def harvest_evals(context, store, locations, definitions, writers)
        writing = locations.select { |key, _| definitions.key?(key) && writers.include?(key) }
        return if writing.empty?

        rounds(writing.transform_values { |by_arguments| by_arguments.keys.to_set }).each do |active|
          typings = check_definitions(context, store, active, definitions)

          active.each do |key, arguments|
            path, def_node = definitions.fetch(key)
            typing = typings[path] or next

            sources = eval_sources(context, store, typing, def_node, definitions, writers, Set[key])
            next if sources.empty?

            writing.fetch(key).fetch(arguments).each { |site| @evals[site] = sources }
          end
        end
      end

      # What this body writes, in the order it writes it: its own writes, and
      # what the writers it calls write. A macro that evals once and then hands
      # off produces both, and the class gets them in source order — the order
      # the consumer places them in.
      #
      # `reading` holds the methods already being read on this chain, so a
      # writer that reaches itself is read once.
      def eval_sources(context, store, typing, def_node, definitions, writers, reading, self_target = nil)
        Evals.effects(typing, def_node, writers, overrides: @overrides).flat_map do |effect|
          next [Evals.chunk_of(typing, effect, context.subtyping.factory.env, self_target)] unless effect.kind == :frame
          # Code is written there and this call site does not decide what: a
          # hole, the same answer an eval it cannot fold gets.
          next [nil] unless effect.certain
          next [] if reading.include?(effect.callee)

          frame_sources(context, store, typing, effect, definitions, writers, reading, self_target)
        end
      end

      # The callee is checked under the arguments this call hands it, so a
      # parameter is typed as what was passed: `Writer.generate(self, name)`
      # makes `owner` the class whose call site ran the macro, and a module that
      # class builds and hands on is that module. A write on `self` there lands
      # on the call's receiver, and is a hole where that names no class.
      def frame_sources(context, store, typing, effect, definitions, writers, reading, self_target)
        entry = definitions[effect.callee] or return [nil]
        path, callee_node = entry
        arguments = Specializations::Arguments.recorded(effect.node, typing) or return [nil]
        frame_self = typing.self_type_of_call(node: effect.node) or return [nil]
        arguments = arguments.resolve_self(frame_self)
        if Evals.on_self?(effect.node)
          arguments = arguments.with_self(frame_self)
        else
          self_target = Evals.eval_target(typing, effect.node) || Evals::UNNAMED_SELF
        end
        inner = check_definitions(context, store, { effect.callee => arguments }, definitions)[path] or return [nil]
        eval_sources(context, store, inner, callee_node, definitions, writers, reading | [effect.callee], self_target)
      end

      def harvest_defines(context, store, locations, definitions)
        @harvested.harvest(locations, definitions, @definers, overrides: @overrides, rounds: method(:rounds), check: ->(active) { check_definitions(context, store, active, definitions) })
      end

      # A call omitting an optional parameter does not leave it open: the body
      # runs with the definition's default, so the calls it makes, the value it
      # returns and the chunk it writes can all turn on exactly that. A `.new`
      # runs its `initialize` on an object that holds nothing yet.
      def with_defaults(key, arguments, def_node)
        positionals, keywords = Collector.defaults(def_node)
        arguments = arguments.with_self_ivars(fresh_ivars(key)) if Collector.constructor?(key, def_node)
        arguments.with_defaults(positionals: positionals, keywords: keywords)
      end

      def fresh_ivars(key)
        name, = Specializations.method_key_parts(key)
        @factory.definition_builder.build_instance(name).instance_variables.keys.to_h { |ivar| [ivar, AST::Builtin.nil_type] }
      rescue RBS::BaseError
        {}
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
            next if widened?(key, arguments, generation)

            (grown[key] ||= Set.new) << arguments
            (@growth[key] ||= Set.new) << generation
          end
        end

        grown
      end

      # Whether this tuple's literals rise to their classes instead of fixing a
      # value. Widening one and dropping it are the same thing here: a tuple that
      # fixes nothing records the declaration back.
      # A key naming its receiver's contents (`Arguments#stateful?`) is found
      # one statement at a time, so no count of generations bounds it; the size
      # of the contents does.
      # A key fixing only the class a body runs on cannot keep growing: the
      # project has finitely many.
      def widened?(key, arguments, generation)
        return arguments.key.length > STATE_WIDTH if arguments.stateful?
        return false if arguments.self_type && !arguments.fixes_a_value?

        kept_growing?(key, generation) || arguments.argument_types.any? { |type| type.to_s.length > LITERAL_WIDTH }
      end

      # A call chain hands each frame its tuple one generation after the frame
      # before it, so how deep a frame sits says nothing about growth.
      def kept_growing?(key, generation) = (@growth.fetch(key, Set.new) - [generation]).size >= WIDEN_AFTER

      def record_exit(key, arguments, typing, def_node)
        return unless typing

        exit = typing.exit_ivars_of(node: def_node)
        store_exit(key, arguments, exit) if ObjectStates::KeptSelf.exit_kept?(arguments, exit)
      end

      def store_exit(key, arguments, exit)
        exit ? (@exits[key] ||= {})[arguments.key] = exit : @exits[key]&.delete(arguments.key)
      end

      # An exit a call needs before any generation has checked its tuple: the
      # body checked there under it, so a chain of writes to one object
      # settles in the generation that walks it instead of one generation per
      # write. Memoized per generation, since `store` changes between them.
      #
      # Inside such a check, only the body it checks asks: the rest of its file
      # is walked too, under contents nothing has settled. A body that writes
      # through another one is what asks there, and a tuple already being
      # checked further out is not checked again.
      def demand_exit(context, definitions, demanded, store, key, arguments, in_checked_body)
        return nil unless @demanding.empty? || in_checked_body
        return nil if !(arguments.stateful? || arguments.hands_records?) || !definitions.key?(key) || widened?(key, arguments, 0)

        memo = [key, arguments.key] #: [String, String]
        return demanded[memo] if demanded.key?(memo)
        return nil unless @demanding.add?(memo)

        begin
          path, def_node = definitions.fetch(key)
          typing = type_check(context, store.with_reads(nil), context.sources.fetch(path), { node_key(path, def_node, key) => with_defaults(key, arguments, def_node) })
          record_exit(key, arguments, typing, def_node)
        ensure
          @demanding.delete(memo)
        end
        demanded[memo] = @exits.dig(key, arguments.key)
      end

      def store(methods)
        Store.new(
          methods: methods.transform_values { |entries| entries.transform_values(&:to_s) },
          source: nil, typed: methods, exits: @exits, demand: @demand, class_exits: @class_exits, receivers: @receivers, bodies: @harvested.bodies
        )
      end

      # The argument tuples the call sites in `paths` supply when read under
      # `store`. Separate from `collect`, which also needs each body's type and so
      # The methods that write code — a string eval, a `const_set`, an
      # `include` — which is the only thing the eval harvest reads. A pure walk
      # of trees already parsed, so a project without the idiom pays this and
      # nothing else. A method that calls one of them writes code too, so the
      # set grows until no call adds one.
      def code_writers(context, defines: false)
        writers = Set[] #: Set[String]
        definitions = context.sources.each_value.flat_map { |source| Collector.definitions(source).to_a }

        loop do
          grown = definitions.filter_map do |key, def_node|
            key if !writers.include?(key) && Evals.writes_code?(def_node, writers, defines: defines)
          end
          break if grown.empty?

          writers.merge(grown)
        end

        writers
      end

      def call_sites(context, store, definitions, paths, locations, writers)
        tuples = {} #: Hash[String, Set[Arguments]]

        paths.each do |path|
          source = context.sources[path] or next
          typing = file_check(context, store, source, {})

          Collector.each_call_site(typing, overrides: @overrides) do |key, arguments, node|
            next @harvested.remember({ key => Collector.tuples(key, arguments) }, definitions) unless definitions.key?(key)

            (tuples[key] ||= Set.new).merge(Collector.tuples(key, arguments))
            record_location(locations, key, arguments, path, node, typing) if writers.include?(key)
          end
        end

        tuples
      end

      # Keyed by the `self` the body runs with there as well as by the
      # arguments: what a macro writes can depend on which class it runs in, and
      # one inherited by a subclass runs in the subclass.
      def record_location(locations, key, arguments, path, node, typing)
        # Calls made with a block are not harvested yet (felixefelip/steep#272).
        return unless node.type == :send

        expression = node.loc.expression or return
        site = "#{@project.relative_path(path)}:#{expression.line}:#{expression.column}"
        arguments = arguments.with_self(CalleeSelf.of(typing, node))

        # A site re-read under a later generation's findings is that site under
        # what it passes now, not also under what it passed before.
        by_arguments = (locations[key] ||= {})
        by_arguments.each_value { |sites| sites.delete(site) }
        by_arguments.delete_if { |_, sites| sites.empty? }
        (by_arguments[arguments] ||= Set.new) << site
      end

      # The union of what each call returned, for each method in `found` whose
      # every call is answered. Read under the settled findings, which is what
      # the calls pass once every inner call has specialized.
      def call_site_unions(context, store, found, baselines, callees, definitions)
        reader = CallSiteUnions::Reader.new(
          store: store, factory: context.subtyping.factory, definitions: definitions,
          sites: call_site_reader(context, store, callees), check: body_checker(context, store, definitions)
        )

        found.each_key.filter_map do |key|
          next if Collector.constructor?(key, definitions.fetch(key)[1])

          union = reader.union(key) or next
          union = Specializations.rbs_writable(union)
          [key, union.to_s] unless union.to_s == baselines[key]
        end.to_h
      end

      def call_site_reader(context, store, callees)
        by_path = Hash.new do |hash, path|
          sites = Hash.new { |by_key, key| by_key[key] = [] } #: Hash[String, Array[untyped]]
          typing = type_check(context, store, context.sources.fetch(path), {})
          Collector.each_call_site(typing, overrides: @overrides, every_call: true) { |key, arguments, node| sites[key] << [path, node, arguments] }
          hash[path] = sites
        end

        ->(key) { affected_paths(callees, Set[key]).flat_map { |path| by_path[path].fetch(key, []) } }
      end

      def body_checker(context, store, definitions)
        checked = {} #: Hash[[String, Arguments], Typing]
        lambda do |key, arguments|
          checked[[key, arguments]] ||= begin
            path, def_node = definitions.fetch(key)
            type_check(context, store, context.sources.fetch(path), { node_key(path, def_node, key) => arguments })
          end
        end
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

        status = Services::SignatureService.load_from(loader, implicitly_returns_nil: target.implicitly_returns_nil, underscore_casts: target.underscore_casts).status
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
          typing = file_check(context, store, source, {})
          record_receivers(typing, source)

          Collector.definitions(source).each do |key, def_node|
            definitions[key] = [path, def_node]
            type = body_type(typing, def_node)
            baselines[key] = Specializations.rbs_writable(type).to_s if type
          end

          Collector.each_call_site(typing, overrides: @overrides) do |key, arguments, node|
            (tuples[key] ||= Set.new).merge(Collector.tuples(key, arguments))
            record_location(locations, key, arguments, path, node, typing) if writers.include?(key)
          end

          callees[path] = Collector.callees(typing, overrides: @overrides) if typing
        end

        @harvested.remember(tuples, definitions)
        tuples.select! { |key, _| definitions.key?(key) }
        locations.select! { |key, _| definitions.key?(key) }
        [baselines, tuples, definitions, callees]
      end

      def record_receivers(typing, source)
        return unless typing && source.node

        Receivers.record(@receivers, @unknown_receivers, Receivers.collect(typing, source.node, @project.constructor_binding_registry.used_names))
      end

      # One round per tuple position, so a method with two tuples costs two
      # re-checks and a file holding several specialized methods still costs one
      # check per round — the tuples of different methods do not interact.
      def rounds(tuples)
        lists = tuples.transform_values(&:to_a)
        depth = lists.each_value.map(&:size).max || 0

        (0...depth).flat_map do |index|
          @harvested.separate(lists.filter_map { |key, list| [key, list[index]] if list[index] }.to_h)
        end
      end

      # A check is reused where the store answers what it asked as before
      # (`Checks`); one that is not is run in the same place in the round, so
      # what it leaves in the class exits lands in the same order.
      def specialized_checks(context, store, active, definitions)
        active.group_by { |key, _| definitions.fetch(key).first }.to_h do |path, entries|
          bodies = entries.to_h do |key, arguments|
            def_node = definitions.fetch(key)[1]
            [key, [def_node, arguments, node_key(path, def_node, key), with_defaults(key, arguments, def_node)]]
          end
          outcome = @checks.outcome(bodies, store) { |logged, by_node| file_check(context, logged, context.sources.fetch(path), by_node) }
          @class_exits.merge!(outcome.class_exits)
          [path, outcome]
        end
      end

      def check_definitions(context, store, active, definitions)
        paths = active.keys.filter_map { |key| definitions[key]&.first }.uniq
        by_node = active.to_h do |key, arguments|
          path, def_node = definitions.fetch(key)
          [node_key(path, def_node, key), with_defaults(key, arguments, def_node)]
        end

        paths.to_h do |path|
          [path, file_check(context, store, context.sources.fetch(path), by_node)]
        end
      end

      # What the checker matches a body by, since the name it would derive from
      # the self type is not always the name this pass keys the body under.
      def node_key(path, def_node, key)
        [path.to_s, def_node.loc.expression.begin_pos, *(key if @harvested.harvested?(key))]
      end

      # A check of a whole file at this run's top level, not one a demanded
      # exit nests in another, which is the one that leaves its class bodies
      # settled as far as `store` lets them.
      def file_check(context, store, source, active)
        type_check(context, store, source, active).tap do |typing|
          @class_exits.merge!(typing.class_exits) if typing
        end
      end

      # `store` is always one this run computed, never the sidecar on disk:
      # reading what it is about to overwrite would make every run one more
      # generation of a fixpoint whose bound is per-run.
      def type_check(context, store, source, active)
        Services::TypeCheckService.type_check(
          source: checked_source(source, active),
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

      # A check under substituted parameters is read for the bodies it
      # substitutes, so the rest of the file is left out of it. One under none
      # is read for every call the file makes, and keeps it whole.
      def checked_source(source, active)
        positions = active.keys.filter_map { |path, position| position if path == source.path.to_s }.sort
        return source if positions.empty?

        @pruned[[source.path, positions]] ||= Source::OnlyDefs.new(
          source, Collector.definitions(source).each_value.select { |def_node| positions.include?(def_node.loc.expression.begin_pos) } +
                  positions.filter_map { |position| @harvested.kept_def([source.path.to_s, position]) }
        )
      end

      def returned_type(typing, def_node, key)
        Collector.constructor?(key, def_node) ? ObjectStates::Constructed.state(typing, def_node, key) : body_type(typing, def_node)
      end

      def body_type(typing, def_node)
        return nil unless typing

        body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
        return nil unless body && typing.has_type?(body)

        values = Returns.values(typing, body) or return nil
        types = [typing.type_of(node: body), *values].reject { |type| type.is_a?(AST::Types::Bot) }
        return nil if types.empty? || types.any? { |type| type.is_a?(AST::Types::Any) }

        AST::Types::Union.build(types: types.reject { |type| type.is_a?(AST::Types::ObjectState) && types.include?(type.back_type) })
      end
    end
  end
end

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
    # One hop: pass 2 reads the declarations, not the specializations pass 1
    # found, so a specialized return does not yet flow into the next caller.
    # Iterating that is felixefelip/rbs_infer#345 stage S5, and needs a widening
    # operator to terminate.
    class Runner
      DEFAULT_OUTPUT_PATH = Pathname("sig/generated/.steep_specializations.yml").freeze

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
      end

      def run
        methods = {} #: Hash[String, Hash[String, String]]
        @project.targets.each { |target| specialize_target(target, methods) }
        methods
      end

      def output_path
        @project.absolute_path(DEFAULT_OUTPUT_PATH)
      end

      def write(methods)
        if methods.empty?
          output_path.delete if output_path.file?
        else
          Writer.write(output_path, methods)
        end
      end

      private

      def specialize_target(target, methods)
        context = load_target(target) or return

        baselines, tuples, definitions = collect(context)
        return if tuples.empty?

        rounds(tuples).each do |active|
          typings = check_definitions(context, active, definitions)

          active.each do |key, arguments|
            path, def_node = definitions.fetch(key)
            type = body_type(typings[path], def_node) or next
            next if type.to_s == baselines[key]

            (methods[key] ||= {})[arguments.key] = type.to_s
          end
        end
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

      def collect(context)
        baselines = {} #: Hash[String, String]
        tuples = {} #: Hash[String, Set[Arguments]]
        definitions = {} #: Hash[String, [Pathname, Parser::AST::Node]]

        context.sources.each do |path, source|
          typing = type_check(context, source, {})

          Collector.definitions(source.node).each do |key, def_node|
            definitions[key] = [path, def_node]
            type = body_type(typing, def_node)
            baselines[key] = type.to_s if type
          end

          Collector.call_sites(typing).each do |key, arguments|
            (tuples[key] ||= Set.new).merge(arguments)
          end
        end

        tuples.select! { |key, _| definitions.key?(key) }
        [baselines, tuples, definitions]
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

      def check_definitions(context, active, definitions)
        paths = active.keys.filter_map { |key| definitions[key]&.first }.uniq

        paths.to_h do |path|
          [path, type_check(context, context.sources.fetch(path), active)]
        end
      end

      # The runner recomputes from the declarations every time: reading the
      # sidecar it is about to overwrite would make each run one more round of a
      # fixpoint nobody bounded.
      def type_check(context, source, active)
        Services::TypeCheckService.type_check(
          source: source,
          subtyping: context.subtyping,
          constant_resolver: context.constant_resolver,
          cursor: nil,
          contracts: @project.contracts,
          postconditions: @project.postconditions,
          callbacks: @project.callbacks,
          specializations: Store.empty.with_active(active),
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

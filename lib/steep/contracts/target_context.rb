module Steep
  module Contracts
    # The part of a target's setup that contract inference re-reads on every pass and
    # that CANNOT change while it runs: the loaded RBS environment and the parsed
    # sources.
    #
    # Both `Runner#infer_for_target` and `Enforcement#collect_for_target` used to build
    # this themselves, and `close_and_enforce` calls the latter once per fixpoint pass.
    # On a Rails project that meant reloading every RBS file (stdlib + gems +
    # gem_rbs_collection + the app's own generated `sig/`) and re-parsing every source,
    # eleven times over — 91% of a `steep check` run before this existed, with the
    # actual type-checking a small remainder.
    #
    # Only the contracts STORE differs between passes, and it is an argument to
    # `type_check`, not to the environment. So this is built once per target per run and
    # handed to both consumers.
    #
    # Not a cache with invalidation on purpose: an instance's lifetime is one contract
    # run, during which no `.rbs` or `.rb` on disk is written. Anything longer-lived
    # would need to answer "what if the file changed?", which is the language server's
    # problem, not this one's.
    class TargetContext
      attr_reader :subtyping
      attr_reader :constant_resolver

      # `[[Pathname, Source]]` for the target's checkable sources, already parsed. Files
      # that fail to parse are dropped here rather than at each use site, so a syntax
      # error is skipped once instead of raising on every pass.
      attr_reader :sources

      # nil when the target's signatures do not load (`LoadedStatus` is the only status
      # carrying a subtyping check) — callers treat that as "nothing to analyze", which
      # is what they did with the early `return` this replaces.
      def self.build(project, target)
        loader = Project::Target.construct_env_loader(options: target.options, project: project)
        file_loader = Services::FileLoader.new(base_dir: project.base_dir)

        file_loader.each_path_in_patterns(target.signature_pattern) do |path|
          absolute = project.absolute_path(path)
          loader.add(path: absolute) if absolute.file?
        end

        signature_service = Services::SignatureService.load_from(loader, implicitly_returns_nil: target.implicitly_returns_nil)
        status = signature_service.status
        return nil unless status.is_a?(Services::SignatureService::LoadedStatus)

        subtyping = status.subtyping
        sources = []

        file_loader.each_path_in_patterns(target.source_pattern) do |path|
          absolute = project.absolute_path(path)
          next unless absolute.file? && absolute.extname == ".rb"

          source = begin
                     Source.parse(absolute.read, path: absolute, factory: subtyping.factory)
                   rescue ::Parser::SyntaxError, AnnotationParser::SyntaxError
                     next
                   end

          sources << [absolute, source]
        end

        new(subtyping: subtyping, constant_resolver: status.constant_resolver, sources: sources)
      end

      def initialize(subtyping:, constant_resolver:, sources:)
        @subtyping = subtyping
        @constant_resolver = constant_resolver
        @sources = sources
      end

      # Type-checks one source with `contracts` loaded. The only per-pass input is the
      # store; everything else comes from this context.
      def type_check(source, contracts:, project:)
        Services::TypeCheckService.type_check(
          source: source,
          subtyping: subtyping,
          constant_resolver: constant_resolver,
          cursor: nil,
          contracts: contracts,
          postconditions: project.postconditions,
          callbacks: project.callbacks,
          delegation_registry: project.delegation_registry,
          constructor_bindings: project.constructor_binding_registry,
          return_forwarding: project.return_forwarding_registry,
          return_alias: project.return_alias_registry
        )
      end
    end
  end
end

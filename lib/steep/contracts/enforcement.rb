module Steep
  module Contracts
    # Whole-program analysis that decides, for each inferred precondition
    # contract, whether it is actually *enforced* by its call sites.
    #
    # A contract is enforced only when every statically visible call site
    # satisfies the precondition AND at least one such call site exists. A
    # method with zero static call sites (the typical Rails action / mailer /
    # job called by the framework) is NOT enforced: nobody checks the
    # precondition, so narrowing it inside the body would silence real bugs.
    #
    # See felixefelip/steep#20.
    class Enforcement
      # `contexts`: a callable `target -> TargetContext | nil`. REQUIRED, not defaulted:
      # the Runner calls `analyze` once per fixpoint pass, and a default that built its
      # own context would silently reload every RBS file and re-parse every source on
      # each pass — the exact cost this parameter exists to avoid, and invisible except
      # as a slow run.
      def self.analyze(project, store, contexts:)
        new(project, store, contexts: contexts).analyze
      end

      def initialize(project, store, contexts:)
        @project = project
        @store = store
        @contexts = contexts
      end

      # Whole-program analysis result: the `enforced` flag per contract key,
      # plus the transitive precondition `obligations` (`{ key:, expr: }`)
      # harvested from self-calls that the enclosing method does not satisfy.
      Result = Struct.new(:enforced, :obligations, keyword_init: true)

      # Type-checks the whole program with `@store` loaded and returns a
      # `Result`. `enforced[key]` is true when the contract has at least one
      # static call site and every one satisfies it; `obligations` feeds the
      # Runner's transitive-closure fixpoint.
      def analyze
        observations = Hash.new { |h, k| h[k] = { seen: 0, unsatisfied: 0 } }
        obligations = []

        @project.targets.each do |target|
          collect_for_target(target, observations, obligations)
        end

        enforced = @store.methods.each_key.each_with_object({}) do |key, result|
          obs = observations[key]
          result[key] = obs[:seen] > 0 && obs[:unsatisfied] == 0
        end

        Result.new(enforced: enforced, obligations: obligations)
      end

      private

      def collect_for_target(target, observations, obligations)
        context = @contexts.call(target) or return

        context.sources.each do |_path, source|
          # Type-check with the inferred contracts loaded so that
          # check_precondition_at_call_site fires and records observations.
          typing = context.type_check(source, contracts: @store, project: @project)

          typing.contract_call_sites.each do |obs|
            bucket = observations[obs[:key]]
            bucket[:seen] += 1
            bucket[:unsatisfied] += 1 unless obs[:satisfied]
          end

          obligations.concat(typing.precondition_obligations)
        end
      end
    end
  end
end

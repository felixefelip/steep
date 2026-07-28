module Steep
  module Contracts
    class Runner
      def self.run(project)
        new(project).run
      end

      def initialize(project)
        @project = project
        @contexts = {}
      end

      def run
        contracts = []
        @project.targets.each do |target|
          contracts.concat(infer_for_target(target))
        end
        merged = merge(contracts)
        close_and_enforce(merged)
      end

      # The loaded environment + parsed sources for a target, built once and reused by
      # the inference pass and by EVERY enforcement pass. Rebuilding it per pass was the
      # bulk of a `steep check`; see `TargetContext`.
      def context_for(target)
        @contexts.fetch(target.name) { @contexts[target.name] = TargetContext.build(@project, target) }
      end

      def output_path
        @project.absolute_path(Pathname(DEFAULT_SIDECAR_PATH))
      end

      def write(contracts)
        if contracts.empty?
          output_path.delete if output_path.file?
        else
          Writer.write(output_path, contracts)
        end
      end

      private

      def infer_for_target(target)
        context = context_for(target) or return []

        context.sources.flat_map do |_path, source|
          # Real postconditions matter here: with via_receiver / self
          # narrowing in scope, the inferrer can prove nil-safety inside
          # method bodies and *avoid* emitting a precondition the body no
          # longer needs. Always pass the project's loaded store, not
          # `Store.empty` — felixefelip/steep#14 follow-up.
          typing = context.type_check(source, contracts: Store.empty, project: @project)

          Inferrer.infer(source, typing, return_aliases: @project.return_alias_registry.to_h)
        end
      end

      # Close preconditions over the self-call graph and decide enforcement,
      # together, at a fixpoint. Each pass loads the current contracts (with
      # the best-known `enforced` flags) and type-checks the whole program,
      # which both (a) observes call sites to recompute enforcement and (b)
      # harvests transitive obligations — a `self` call to a contracted method
      # that the enclosing method does not satisfy makes that method inherit
      # the requirement. Adding an inherited requirement can make a method's
      # own precondition provable at its call sites (the callers establish it),
      # flipping enforcement on — so obligations and enforcement are resolved
      # together. Bounded by MAX_PASSES; the last computed flags are used if it
      # does not converge. See felixefelip/steep#20 (enforcement) and the
      # transitive-closure follow-up.
      MAX_PASSES = 20

      def close_and_enforce(contracts)
        return contracts if contracts.empty?

        by_key = contracts.each_with_object({}) { |c, h| h[c.key] = c }
        enforced = {} #: Hash[String, bool]

        MAX_PASSES.times do
          store = build_store(by_key, enforced)
          result = Enforcement.analyze(@project, store, contexts: method(:context_for))

          obligations_changed = apply_transitive_obligations(by_key, result.obligations)
          enforced_changed = result.enforced != enforced
          enforced = result.enforced

          break unless obligations_changed || enforced_changed
        end

        by_key.values.map { |c| c.with_enforced(enforced.fetch(c.key, false)) }
      end

      def build_store(by_key, enforced)
        methods = by_key.each_with_object({}) do |(key, contract), h|
          h[key] = contract.with_enforced(enforced.fetch(key, false))
        end
        Store.new(methods: methods, source: nil)
      end

      # Adds each inherited requirement to its enclosing method's contract
      # (creating an empty contract if the method had none). Returns whether
      # any contract gained a new requirement this pass.
      def apply_transitive_obligations(by_key, obligations)
        changed = false
        obligations.each do |obligation|
          key = obligation[:key]
          predicate = Predicate::NotNil.new(obligation[:expr])
          contract = by_key[key] || empty_contract(key)
          seen = contract.requires.map { |r| predicate_signature(r) }.to_set
          next if seen.include?(predicate_signature(predicate))

          by_key[key] = MethodContract.new(
            type_name: contract.type_name,
            method_name: contract.method_name,
            singleton: contract.singleton,
            requires: contract.requires + [predicate]
          )
          changed = true
        end
        changed
      end

      def empty_contract(key)
        type_name, separator, method = key.partition(/[#.]/)
        MethodContract.new(
          type_name: type_name,
          method_name: method.to_sym,
          singleton: separator == ".",
          requires: []
        )
      end

      def merge(contracts)
        by_key = {}
        contracts.each do |c|
          key = "#{c.type_name}#{c.singleton ? '.' : '#'}#{c.method_name}"
          if (existing = by_key[key])
            seen = existing.requires.map { |r| predicate_signature(r) }.to_set
            extras = c.requires.reject { |r| seen.include?(predicate_signature(r)) }
            by_key[key] = MethodContract.new(
              type_name: existing.type_name,
              method_name: existing.method_name,
              singleton: existing.singleton,
              requires: existing.requires + extras
            )
          else
            by_key[key] = c
          end
        end
        by_key.values
      end

      def predicate_signature(predicate)
        case predicate
        when Predicate::NotNil then [:not_nil, expr_signature(predicate.expr)]
        end
      end

      def expr_signature(expr)
        case expr
        when Expr::SelfRef then [:self]
        when Expr::Send then [:send, expr_signature(expr.receiver), expr.method, expr.chain]
        end
      end
    end
  end
end

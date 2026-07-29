require_relative "test_helper"

# felixefelip/steep#105 follow-up: the guard collector reads what the checker
# concluded about a condition (`typing.branch_envs`) instead of re-deriving it
# from the AST.
#
# Two things this buys, both of which the syntactic reading got wrong:
#
#   * ANY predicate the RBS describes, not a hardcoded shape list.
#     `LogicTypeInterpreter#evaluate_union_method_call` already partitions a
#     union receiver by each component's declared return type, so
#     `account.present?` (`NilClass#present?: () -> false`) and
#     `account.blank?` (`NilClass#blank?: () -> true`) both narrow, in opposite
#     branches, with no knowledge of ActiveSupport anywhere in Steep.
#   * POLARITY. `redirect_to :x if account` halts when the account is PRESENT,
#     so the surviving exit is the one where it is nil — and must prove nothing.
class PostconditionsGuardBranchEnvTest < Minitest::Test
  include TestHelper
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  Postconditions = Steep::Postconditions

  # `Object#present?: () -> bool` / `NilClass#present?: () -> false` is exactly
  # the shape activesupport's own RBS ships.
  RBS_FIXTURE = <<~RBS
    class Object
      def present?: () -> bool
      def blank?: () -> bool
    end

    class NilClass
      def present?: () -> false
      def blank?: () -> true
    end

    class GBAccount
      def active?: () -> bool
    end

    class GBUser
      def active?: () -> bool
    end

    class GBCurrent
      def self.account: () -> GBAccount?
      def self.user: () -> GBUser?
    end

    class GBController
      def redirect_to: (untyped) -> void
      def current_user: () -> GBUser?
      def present_guard: () -> void
      def blank_guard: () -> void
      def bare_guard: () -> void
      def negated_guard: () -> void
      def inverted_guard: () -> void
      def method_call_guard: () -> void
      def safe_nav_guard: () -> void
      def self_method_guard: () -> void
    end
  RBS

  def infer_for(ruby, record_branch_envs:)
    entries = nil
    with_checker(RBS_FIXTURE) do |checker|
      source = parse_ruby(ruby)
      with_standard_construction(checker, source, record_branch_envs: record_branch_envs) do |construction, typing|
        construction.synthesize(source.node)
        entries = Postconditions::Inferrer.infer(source, typing, checker)
      end
    end
    entries
  end

  SOURCE = <<~RUBY
    class GBController
      def present_guard
        unless GBCurrent.account.present?
          redirect_to :login
        end
      end

      def blank_guard
        if GBCurrent.account.blank?
          redirect_to :login
        end
      end

      def bare_guard
        unless GBCurrent.account
          redirect_to :login
        end
      end

      def negated_guard
        if !GBCurrent.account
          redirect_to :login
        end
      end

      def inverted_guard
        redirect_to :root if GBCurrent.account
      end

      def method_call_guard
        unless GBCurrent.account.active?
          redirect_to :login
        end
      end

      def safe_nav_guard
        unless GBCurrent.account.active? && GBCurrent.user&.active?
          redirect_to :login
        end
      end

      def self_method_guard
        unless current_user.present?
          redirect_to :login
        end
      end
    end
  RUBY

  def const_returns(entries)
    entries.each_with_object({}) do |entry, hash|
      next if entry.conditional_const_returns.empty?
      hash[entry.method_name] = entry.conditional_const_returns.transform_values {|spec| spec[:type].to_s }
    end
  end

  def self_returns(entries)
    entries.each_with_object({}) do |entry, hash|
      next if entry.conditional_returns.empty?
      hash[entry.method_name] = entry.conditional_returns.transform_values {|spec| spec[:type].to_s }
    end
  end

  def test_reads_branch_envs
    facts = const_returns(infer_for(SOURCE, record_branch_envs: true))

    # Any predicate the RBS declares as falsy-on-nil, either polarity.
    assert_equal({ "GBCurrent.account" => "::GBAccount" }, facts[:present_guard])
    assert_equal({ "GBCurrent.account" => "::GBAccount" }, facts[:blank_guard])
    assert_equal({ "GBCurrent.account" => "::GBAccount" }, facts[:bare_guard])
    assert_equal({ "GBCurrent.account" => "::GBAccount" }, facts[:negated_guard])

    # Halts when PRESENT: the surviving exit has a nil account, so nothing holds.
    assert_nil facts[:inverted_guard]

    # `NilClass#active?` is not declared, so a truthy result says nothing about
    # the receiver — the model does not reason about the call raising.
    assert_nil facts[:method_call_guard]

    # `x&.foo` truthy proves `x` non-nil, but the env cannot hold that for a
    # CONSTANT PATH: `:csend` synthesis joins the env back to its pre-call state,
    # dropping the receiver's pure-call registration. The syntactic reading is
    # unioned in exactly to cover that hole — and `account.active?`, the other
    # conjunct, still proves nothing.
    assert_equal({ "GBCurrent.user" => "::GBUser" }, facts[:safe_nav_guard])
  end

  # The same reading, for a fact the guard names as a SELF METHOD rather than a
  # constant path — the `conditional_returns` half of the collector. Both halves
  # consume `guard_facts`, so this pins that the env-derived fact reaches the one
  # keyed by method name too.
  def test_reads_branch_envs_for_self_methods
    facts = self_returns(infer_for(SOURCE, record_branch_envs: true))

    assert_equal({ current_user: "::GBUser" }, facts[:self_method_guard])
  end

  # Without the recorded envs the syntactic fallback still handles the shapes it
  # always did, and — the fix — no longer inverts the polarity of `if X; halt; end`.
  def test_syntactic_fallback
    facts = const_returns(infer_for(SOURCE, record_branch_envs: false))

    assert_equal({ "GBCurrent.account" => "::GBAccount" }, facts[:bare_guard])
    assert_equal({ "GBCurrent.account" => "::GBAccount" }, facts[:negated_guard])
    assert_nil facts[:inverted_guard]
    assert_nil facts[:present_guard]
    assert_nil facts[:blank_guard]
    assert_equal({ "GBCurrent.user" => "::GBUser" }, facts[:safe_nav_guard])

    # `current_user.present?` is a predicate on the slot, not the slot itself, so
    # the AST reading has nothing to name — this fact exists only in the env.
    assert_nil self_returns(infer_for(SOURCE, record_branch_envs: false))[:self_method_guard]
  end

  # The cost claim: the envs are retained only for the pass that asks for them,
  # so the check driver and the LSP keep paying nothing.
  def test_records_only_when_asked
    with_checker(RBS_FIXTURE) do |checker|
      source = parse_ruby(SOURCE)

      with_standard_construction(checker, source, record_branch_envs: false) do |construction, typing|
        construction.synthesize(source.node)
        assert_empty typing.branch_envs
      end

      with_standard_construction(checker, source, record_branch_envs: true) do |construction, typing|
        construction.synthesize(source.node)
        refute_empty typing.branch_envs
      end
    end
  end
end

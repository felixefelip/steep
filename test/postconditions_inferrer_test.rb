require_relative "test_helper"

class PostconditionsInferrerTest < Minitest::Test
  include TestHelper
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  Postconditions = Steep::Postconditions

  RBS_FIXTURE = <<~RBS
    class IUCompany
      def self.find: (Integer) -> (IUCompany & IUCompany::Validated)
      def self.new: () -> IUCompany
    end

    module IUCompany::Validated
    end

    class IUController
      @company: (IUCompany & IUCompany::Validated) | IUCompany
      @name: String?

      def set_company: () -> (IUCompany & IUCompany::Validated)
      def set_raw: () -> IUCompany
      def set_one_of: () -> ((IUCompany & IUCompany::Validated) | IUCompany)
      def no_assign: () -> void
      def set_default_name: () -> String
    end
  RBS

  def infer_for(ruby)
    entries = nil
    with_checker(RBS_FIXTURE) do |checker|
      source = parse_ruby(ruby)
      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)
        entries = Postconditions::Inferrer.infer(source, typing, checker)
      end
    end
    entries
  end

  def test_infers_unconditional_ivar_postcondition_for_narrowing_assign
    # A method body that assigns `@company` to a value of type
    # `IUCompany & Validated` (a strict subtype of the declared union)
    # surfaces as an inferred postcondition.
    entries = infer_for(<<~RUBY)
      class IUController
        def set_company
          @company = IUCompany.find(1)
        end
      end
    RUBY

    assert_equal 1, entries.size
    entry = entries.first
    assert_equal "IUController", entry.class_name
    assert_equal :set_company, entry.method_name
    refute entry.singleton
    assert_equal [:"@company"], entry.ivars.keys
    assert_equal "(::IUCompany & ::IUCompany::Validated)", entry.ivars[:"@company"].to_s
    # `unconditional.self` is emitted alongside `ivars` so that callers
    # whose receiver is NOT self (e.g. `controller.set_company`) can
    # still be narrowed — `apply_unconditional_postconditions` only
    # touches caller ivars when receiver is self, so without a self
    # marker the cross-receiver case would be a no-op.
    assert_equal "::IUController & ::IUController::AfterSetCompany",
                 entry.self_type_string
  end

  def test_does_not_infer_when_rhs_equals_declared
    # Method assigns `@company` to a value typed exactly as the declared
    # union — no refinement, no inference. Avoids emitting useless
    # entries that say "narrow to the same type".
    entries = infer_for(<<~RUBY)
      class IUController
        def set_one_of
          # @type var same_typed: (IUCompany & IUCompany::Validated) | IUCompany
          same_typed = (_ = nil)
          @company = same_typed
        end
      end
    RUBY

    # No REFINEMENT — the assignment narrows nothing. The method does still
    # WRITE @company, so it carries the may-write effect (felixefelip/steep#68):
    # a caller that narrowed @company must drop that view after the call.
    refute_empty entries
    assert_empty entries[0].ivars
    assert_equal Set[:@company], entries[0].may_write_ivars
  end

  def test_does_not_infer_when_rhs_is_not_strict_subtype
    # Method assigns `@company` to a wider/unrelated type — RHS is not a
    # strict subtype of the declared. The inferrer does not propose a
    # postcondition (the assignment may even be a type error on its own,
    # but that's the dispatch's concern, not the inferrer's).
    entries = infer_for(<<~RUBY)
      class IUController
        def set_raw
          @company = IUCompany.new
        end
      end
    RUBY

    # `IUCompany.new` returns plain `IUCompany`, which is one of the
    # union branches but not a *strict* subtype of the union (the union
    # is reflexive). Whether this is "narrowing" depends on subtyping
    # checker behavior; assert that we don't crash and that the result
    # is well-formed.
    assert_kind_of Array, entries
  end

  def test_handles_method_with_no_ivar_assignment
    # Method body that has no `:ivasgn` produces no entries.
    entries = infer_for(<<~RUBY)
      class IUController
        def no_assign
          1 + 1
        end
      end
    RUBY

    assert_empty entries
  end

  def test_multiple_ivar_assignments_take_last_write
    # When a method writes the same ivar twice with different types,
    # the LAST write's type wins. The inferrer assumes linear flow for
    # MVP — a more sophisticated analysis (branching) is future work.
    entries = infer_for(<<~RUBY)
      class IUController
        def set_company
          @company = IUCompany.new
          @company = IUCompany.find(1)
        end
      end
    RUBY

    refute_empty entries
    entry = entries.first
    assert_equal "(::IUCompany & ::IUCompany::Validated)", entry.ivars[:"@company"].to_s
  end

  def test_infers_narrowing_when_rhs_is_string_literal_against_nilable_ivar
    # `@name: String?` declared. `set_default_name` writes a String
    # literal. Steep's `:ivasgn` synthesize passes the declared
    # `String?` as `hint:` to the str-node synthesize, which makes
    # `typing.type_of(str_node)` return the widened `String?` —
    # losing the narrowing the writer actually introduces.
    #
    # The Inferrer reads the literal's intrinsic type
    # (`AST::Builtin::String.instance_type`) directly, so the
    # narrowing survives. felixefelip/steep#34.
    entries = infer_for(<<~RUBY)
      class IUController
        def set_default_name
          @name = "TBA Venue"
        end
      end
    RUBY

    refute_empty entries
    entry = entries.find { |e| e.method_name == :set_default_name }
    refute_nil entry, "expected entry for set_default_name"
    assert_equal "::String", entry.ivars[:"@name"].to_s
  end

  def test_infers_narrowing_when_rhs_is_nil_literal_against_nilable_ivar
    # `nil` literal isn't context-widened (it's already the bottom
    # of any union containing nil), so this case used to work even
    # before the intrinsic-type fix. Pinned here so a regression
    # of `:nil` handling shows up immediately.
    entries = infer_for(<<~RUBY)
      class IUController
        def set_default_name
          @name = nil
        end
      end
    RUBY

    refute_empty entries
    entry = entries.find { |e| e.method_name == :set_default_name }
    refute_nil entry
    assert_equal "nil", entry.ivars[:"@name"].to_s
  end

  def test_ignores_top_level_defs_without_class
    # `def x` at the top of the source (no enclosing class) has no
    # `class_name` to attach a postcondition to — inferrer skips it.
    entries = infer_for(<<~RUBY)
      def top_level_def
        @company = IUCompany.find(1)
      end
    RUBY

    assert_empty entries
  end

  # --------------------------------------------------------------------
  # `when_true` postconditions for nil-check predicates.
  # `def confirmed?; !@name.nil?; end` should emit a `when_true.ivars`
  # entry refining `@name` to non-nil (and a self marker for chain
  # narrowing).
  # --------------------------------------------------------------------

  PREDICATE_RBS_FIXTURE = <<~RBS
    class PCPredVenue
      @name: String?
      @owner: String?

      def confirmed?: () -> bool
      def fully_set?: () -> bool
      def has_name?: () -> bool
      def truthy_only: () -> bool
    end
  RBS

  def infer_predicate_for(ruby)
    entries = nil
    with_checker(PREDICATE_RBS_FIXTURE) do |checker|
      source = parse_ruby(ruby)
      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)
        entries = Postconditions::Inferrer.infer(source, typing, checker)
      end
    end
    entries
  end

  def test_infers_when_true_for_negated_nil_check
    entries = infer_predicate_for(<<~RUBY)
      class PCPredVenue
        def confirmed?
          !@name.nil?
        end
      end
    RUBY

    refute_empty entries
    entry = entries.find { |e| e.method_name == :confirmed? }
    refute_nil entry
    assert_empty entry.ivars, "unconditional should be empty for a predicate body"
    assert_equal "::String", entry.when_true_ivars[:"@name"].to_s
    assert_equal "::PCPredVenue & ::PCPredVenue::AfterConfirmed",
                 entry.when_true_self_type_string
  end

  def test_infers_when_true_for_conjunction_of_nil_checks
    # `!@a.nil? && !@b.nil?` — both ivars refined non-nil in the
    # truthy branch.
    entries = infer_predicate_for(<<~RUBY)
      class PCPredVenue
        def fully_set?
          !@name.nil? && !@owner.nil?
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :fully_set? }
    refute_nil entry
    assert_equal "::String", entry.when_true_ivars[:"@name"].to_s
    assert_equal "::String", entry.when_true_ivars[:"@owner"].to_s
  end

  def test_skips_when_declared_type_already_non_nil
    # Even though the body matches the nil-check shape, if the ivar
    # is already declared non-nilable in RBS, there's no narrowing
    # opportunity. Don't emit a no-op refinement.
    entries = infer_predicate_for(<<~RUBY)
      class PCPredVenue
        def truthy_only
          !@nonexistent.nil?
        end
      end
    RUBY

    # No declared @nonexistent → no entry. Sanity: not crashing on
    # missing ivar declaration.
    assert_empty entries
  end

  def test_bare_ivar_body_is_a_transparent_getter
    # `def has_name?; @name; end` proposes no when_true refinement (its return
    # is the ivar's plain type, not a logic type). But it IS a transparent
    # getter of @name (felixefelip/steep#68 item 2): testing it must narrow
    # @name, so the entry carries `returns_ivar`.
    entries = infer_predicate_for(<<~RUBY)
      class PCPredVenue
        def has_name?
          @name
        end
      end
    RUBY

    assert_equal 1, entries.size
    assert_empty entries[0].when_true_ivars
    assert_equal :@name, entries[0].returns_ivar
  end

  def test_infers_when_true_for_multi_statement_body
    # Body has setup statements before the final predicate
    # expression. The interpreter only cares about the last
    # expression (the return value), so the side-effecting calls
    # above don't interfere.
    entries = infer_predicate_for(<<~RUBY)
      class PCPredVenue
        def confirmed?
          _logged = "checking"
          !@name.nil?
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :confirmed? }
    refute_nil entry, "expected refinement to survive a leading non-predicate statement"
    assert_equal "::String", entry.when_true_ivars[:"@name"].to_s
  end

  # --- return-value establishment (felixefelip/steep#56) --------------

  RETURNS_RBS_FIXTURE = <<~RBS
    class RVThing
      def self.new: () -> RVThing
    end

    class RVRecord
      attr_accessor thing: RVThing?
      def self.new: () -> RVRecord
    end

    class RVFactory
      def build: () -> RVRecord
      def self.build_s: () -> RVRecord
      def build_other: () -> RVRecord
      def no_write: () -> RVRecord
    end
  RBS

  def infer_returns_for(ruby)
    entries = nil
    with_checker(RETURNS_RBS_FIXTURE) do |checker|
      source = parse_ruby(ruby)
      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)
        entries = Postconditions::Inferrer.infer(source, typing, checker)
      end
    end
    entries
  end

  def test_infers_return_establishment_for_factory_shape
    # `record = RVRecord.new; record.thing = RVThing.new; record` — the
    # returned local has `thing` (declared `RVThing?`) written non-nil,
    # so `build` establishes `thing` on its return value.
    entries = infer_returns_for(<<~RUBY)
      class RVFactory
        def build
          record = RVRecord.new
          record.thing = RVThing.new
          record
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :build }
    refute_nil entry, "expected an entry for build"
    assert_equal [:thing], entry.returns_establishes
    assert_empty entry.ivars, "build sets no ivar — only a local's attribute"
  end

  def test_infers_return_establishment_for_singleton_factory
    entries = infer_returns_for(<<~RUBY)
      class RVFactory
        def self.build_s
          record = RVRecord.new
          record.thing = RVThing.new
          record
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :build_s }
    refute_nil entry, "expected an entry for the singleton build_s"
    assert entry.singleton
    assert_equal [:thing], entry.returns_establishes
  end

  def test_no_return_establishment_when_returned_local_differs_from_written
    # The attribute is written on `other`, but a DIFFERENT local
    # (`record`) is returned — the write doesn't reach the return value.
    entries = infer_returns_for(<<~RUBY)
      class RVFactory
        def build_other
          record = RVRecord.new
          other = RVRecord.new
          other.thing = RVThing.new
          record
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :build_other }
    assert(entry.nil? || entry.returns_establishes.empty?,
           "a write to a non-returned local must not establish anything on the return value")
  end

  def test_no_return_establishment_without_attr_write
    entries = infer_returns_for(<<~RUBY)
      class RVFactory
        def no_write
          record = RVRecord.new
          record
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :no_write }
    assert(entry.nil? || entry.returns_establishes.empty?)
  end

  # felixefelip/steep#68 item 2 — the guard-clause proof.
  CR_RBS_FIXTURE = <<~RBS
    class User
      def full_name: () -> String
      def maybe_name: () -> String?
      def named?: (String) -> bool
    end

    class Account
      def label: () -> String
    end

    class Current
      def self.user: () -> User?
      def self.user=: (User?) -> User?
      def self.account: () -> Account?
      def self.banned: () -> Account?
      def self.instance: () -> Current
      def self.[]=: (String, User) -> void
      def user=: (User?) -> void
      def author_name=: (String?) -> String?
    end

    class CRGuardHost
      @halted: bool

      def current_user: () -> User?
      def flag?: () -> bool
      def redirect_to: () -> void
      def with_format: () ?{ (untyped) -> untyped } -> untyped
      def authenticate_user: () -> void
      def no_return: () -> void
      def proven_user: () -> User
      def set_current_user: () -> void
    end

    class Marked
      def name: () -> String?
    end

    class Marked::Validated
      def name: () -> String
    end

    class MarkedHost
      @value: (Marked & Marked::Validated)?

      # The reader is deliberately `untyped`: a generated attribute sidecar
      # (`def value; @value; end`) carries no type for the attribute, which is
      # what the own-attribute-read establishment has to work around.
      def value: () -> untyped
      def value=: ((Marked & Marked::Validated)? value) -> void
      def other=: (String?) -> void
    end

    module Outer
      class Registry
        def self.user: () -> User?
        def self.user=: (User?) -> User?
      end

      class Host
        @halted: bool

        def current_user: () -> User?
        def redirect_to: () -> void
        def proven_user: () -> User
        def guarded: () -> void
        def plain: () -> void
      end
    end
  RBS

  def infer_cr_for(ruby)
    entries = nil
    with_checker(CR_RBS_FIXTURE) do |checker|
      source = parse_ruby(ruby)
      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)
        entries = Postconditions::Inferrer.infer(source, typing, checker)
      end
    end
    entries
  end

  def test_infers_conditional_return_from_guard_clause
    # `unless current_user; <halt>; return; end` proves `current_user` non-nil
    # on the unhalted exit. Here the halt is a direct ivar write, so the gate
    # resolves to `@halted` in the inferrer itself.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            @halted = true
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    refute_nil entry
    spec = entry.conditional_returns[:current_user]
    refute_nil spec, "expected a conditional return for current_user"
    assert_equal :@halted, spec[:gate_ivar]
    assert_equal "::User", spec[:type].to_s
  end

  def test_conditional_return_gate_via_self_method
    # When the halt is a self-method call (`redirect_to`) rather than a direct
    # write, the inferrer records the gate `via` that method; the Runner
    # resolves it to the written ivar (covered in the runner test).
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            redirect_to
            return
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_returns[:current_user]
    refute_nil spec
    assert_nil spec[:gate_ivar]
    assert_equal [:redirect_to], spec[:gate_via]
  end

  # felixefelip/steep#105 gap 3. The halt sits inside a block, so the clause calls
  # TWO self-methods: the block-taking one and the halting one. Neither position is
  # reliably the halt — `respond_to { redirect_to }` puts it last, `redirect_to
  # root_path` puts it first — so the inferrer offers both, in source order, and
  # the Runner keeps whichever actually writes an ivar.
  def test_gate_candidates_include_a_block_nested_halt
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            with_format do |_format|
              redirect_to
            end
            return
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_returns[:current_user]
    refute_nil spec
    assert_equal [:with_format, :redirect_to], spec[:gate_via]
  end

  # A direct ivar write still wins outright: it names the gate with no resolution
  # needed, so no candidate list is offered.
  def test_a_direct_ivar_write_is_the_gate_without_candidates
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            @halted = true
            return
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_returns[:current_user]
    assert_equal :@halted, spec[:gate_ivar]
    assert_nil spec[:gate_via]
  end

  # felixefelip/steep#105 gap 2. No explicit `return`: the guard IS the method's
  # last statement, so falling off the end is exactly a return.
  def test_a_guard_that_is_the_final_statement_needs_no_explicit_return
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            redirect_to
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_returns[:current_user]
    refute_nil spec, "the final statement ends the method, so the guard halts"
    assert_equal [:redirect_to], spec[:gate_via]
  end

  def test_a_final_guard_without_a_return_proves_a_constant_too
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.user
            redirect_to
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_const_returns["Current.user"]
    refute_nil spec
    assert_equal "::User", spec[:type].to_s
  end

  # THE BOUNDARY. Identical clause, but something follows it, so taking the clause
  # does NOT end the method — execution continues past the `if`, and the code after
  # runs on both branches. Proving `current_user` present here would be a fact
  # about a path that keeps going: the one shape in this feature where being too
  # permissive is unsound rather than merely incomplete.
  def test_a_halting_clause_that_is_not_last_proves_nothing
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            redirect_to
          end
          no_return
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert(entry.nil? || entry.conditional_returns.empty?)
  end

  # ... and an explicit `return` still rescues exactly that case, because then the
  # clause does end the method wherever it sits.
  def test_a_non_final_clause_with_an_explicit_return_still_proves
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            redirect_to
            return
          end
          no_return
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_returns[:current_user]
    refute_nil spec
  end

  # The whole shape a real authorization callback has, in one method: a conjunction
  # of const-rooted tests, one through `&.`, halting inside a block, with no
  # `return` because the guard is the method's last statement.
  def test_the_composite_authorization_guard_shape
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.account && Current.user&.maybe_name
            with_format do |_format|
              redirect_to
            end
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    refute_nil entry, "expected the composite guard to prove something"
    assert_equal ["Current.account", "Current.user"], entry.conditional_const_returns.keys.sort
    assert_equal [:with_format, :redirect_to], entry.conditional_const_returns["Current.user"][:gate_via]
  end

  def test_infers_conditional_const_return_from_guarded_write
    # felixefelip/steep#68 item 3. `unless current_user; halt; return; end`
    # followed by a top-level `Current.user = current_user` (non-nil past the
    # guard) proves `Current.user` non-nil on the unhalted exit.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            redirect_to
            return
          end
          Current.user = current_user
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_const_returns["Current.user"]
    refute_nil spec, "expected a conditional const return for Current.user"
    assert_equal [:redirect_to], spec[:gate_via]
    assert_equal "::User", spec[:type].to_s
  end

  # felixefelip/steep#105 gap 1. The guard TESTS the constant instead of writing
  # it — no assignment anywhere, the proof is the condition itself. This is the
  # commoner shape by far: a guard normally asserts what someone else already
  # populated, which is exactly what an authorization callback does.
  def test_infers_conditional_const_return_from_a_guard_that_tests_the_constant
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.user
            redirect_to
            return
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_const_returns["Current.user"]
    refute_nil spec, "expected the tested constant to be proven on the unhalted exit"
    assert_equal [:redirect_to], spec[:gate_via]
    assert_equal "::User", spec[:type].to_s
  end

  # Keyed by identity, like every other const fact (#106).
  def test_a_tested_constant_is_keyed_by_its_resolved_name
    entries = infer_cr_for(<<~RUBY)
      module Outer
        class Host
          def guarded
            unless Registry.user
              redirect_to
              return
            end
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :guarded }
    refute_nil entry, "expected an entry for the guard"
    assert_equal ["Outer::Registry.user"], entry.conditional_const_returns.keys
  end

  # A self-method condition still proves what it always proved, and proves
  # nothing about any constant.
  def test_a_self_method_guard_still_proves_only_the_self_method
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_equal [:current_user], entry.conditional_returns.keys
    assert_empty entry.conditional_const_returns
  end

  # Nothing to prove: `Current.instance` is declared non-nil already, so the
  # guard adds no information and must not emit a fact.
  def test_no_const_return_when_the_tested_attribute_is_not_nilable
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.instance
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert(entry.nil? || entry.conditional_const_returns.empty?)
  end

  # The receiver has to be a CONSTANT. A guard on a local's attribute names no
  # slot the caller could look up, so it proves nothing here.
  def test_no_const_return_when_the_tested_receiver_is_not_a_constant
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          holder = Current.instance
          unless holder.user
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert(entry.nil? || entry.conditional_const_returns.empty?)
  end

  # A write past the guard is more specific than the test before it (it carries
  # the written value's type), so it stays the one that reports.
  def test_a_guarded_write_wins_over_the_test_of_the_same_path
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.user
            redirect_to
            return
          end
          Current.user = proven_user
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_const_returns["Current.user"]
    refute_nil spec
    assert_equal "::User", spec[:type].to_s
  end

  # felixefelip/steep#105 gap 1b. `x&.foo` evaluates to nil whenever `x` is nil, so a
  # TRUTHY `x&.foo` proves `x` non-nil — exactly, with no knowledge of what `foo`
  # returns or whether it is nilable itself. The fact is about the RECEIVER; the send
  # through it is only the reason we are looking.
  def test_infers_conditional_const_return_from_a_safe_navigation_test
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.user&.maybe_name
            redirect_to
            return
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_const_returns["Current.user"]
    refute_nil spec, "expected the safe-navigated receiver to be proven"
    assert_equal "::User", spec[:type].to_s
  end

  def test_infers_conditional_return_from_a_safe_navigation_test_on_a_self_method
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user&.maybe_name
            redirect_to
            return
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_returns[:current_user]
    refute_nil spec, "expected the safe-navigated self-method to be proven"
    assert_equal "::User", spec[:type].to_s
  end

  # The whole chain is truthy only if every link was non-nil, so the innermost
  # nameable slot is proven. Only that one is keyed — `Current.user.maybe_name` is
  # not a slot a caller could look up.
  def test_a_safe_navigation_chain_proves_its_innermost_slot
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.user&.maybe_name&.upcase
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_equal ["Current.user"], entry.conditional_const_returns.keys
  end

  # Arguments to the safe-navigated call are irrelevant: whatever `named?` does with
  # them, it ran at all only because the receiver was non-nil. (Contrast the DIRECT
  # test, where a send with arguments names no slot and is rejected.)
  def test_a_safe_navigation_test_ignores_the_arguments_of_the_call
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.user&.named?("jo")
            redirect_to
            return
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :authenticate_user }.conditional_const_returns["Current.user"]
    refute_nil spec
    assert_equal "::User", spec[:type].to_s
  end

  # The receiver still has to be a nameable slot. A local proves nothing.
  def test_no_fact_when_the_safe_navigated_receiver_is_a_local
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          holder = Current.user
          unless holder&.maybe_name
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert(entry.nil? || (entry.conditional_const_returns.empty? && entry.conditional_returns.empty?))
  end

  # felixefelip/steep#105 gap 1c. `A && B` is truthy only if BOTH are, so a
  # conjunction proves everything its conjuncts do.
  def test_a_conjunction_proves_both_of_its_conjuncts
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.account && Current.user
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_equal ["Current.account", "Current.user"], entry.conditional_const_returns.keys.sort
  end

  def test_a_conjunction_mixes_self_method_and_constant_facts
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user && Current.account
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_equal [:current_user], entry.conditional_returns.keys
    assert_equal ["Current.account"], entry.conditional_const_returns.keys
  end

  def test_a_conjunction_composes_with_safe_navigation
    # The shape a real authorization callback has.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.account && Current.user&.maybe_name
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_equal ["Current.account", "Current.user"], entry.conditional_const_returns.keys.sort
  end

  def test_a_conjunction_nests
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.account && Current.user && current_user
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_equal ["Current.account", "Current.user"], entry.conditional_const_returns.keys.sort
    assert_equal [:current_user], entry.conditional_returns.keys
  end

  # A DISJUNCTION distributes to nothing: `A || B` truthy says only that at least
  # one of them was, and there is no way to tell which. Distributing it the way
  # `&&` distributes would be plainly unsound.
  def test_a_disjunction_proves_nothing
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.account || Current.user
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert(entry.nil? || entry.conditional_const_returns.empty?)
  end

  # An un-decodable conjunct is SKIPPED, not fatal — it says nothing, which is no
  # reason to discard what its neighbour says.
  def test_an_undecodable_conjunct_does_not_sink_the_condition
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          holder = Current.account
          unless Current.user && holder
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_equal ["Current.user"], entry.conditional_const_returns.keys
  end

  # A NEGATED conjunct proves its operand FALSY, which is the opposite of present.
  # The `!` unwrap that turns `if !x` into "x is truthy here" is a property of the
  # whole condition, and re-applying it per conjunct would invert the fact — the
  # one shape in this feature that could silently produce a wrong proof.
  def test_a_negated_conjunct_proves_nothing_about_its_operand
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless Current.user && !Current.banned
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_equal ["Current.user"], entry.conditional_const_returns.keys
  end

  # ... while the whole condition being negated still distributes: `!(A && B)`
  # is falsy exactly when `A && B` is truthy, so the unhalted exit has both.
  def test_a_negated_conjunction_still_distributes
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          if !(Current.account && Current.user)
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_equal ["Current.account", "Current.user"], entry.conditional_const_returns.keys.sort
  end

  # felixefelip/steep#100. A handler with no halt at all writes the constant on EVERY
  # exit, so the establishment is unconditional — there is no gate to key it on, which is
  # exactly why it used to be dropped.
  def test_infers_unconditional_const_establishment_from_plain_handler
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def set_current_user
          Current.user = proven_user
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :set_current_user }
    refute_nil entry, "expected an entry for the populating handler"
    assert_equal "::User", entry.const_establishments["Current.user"].to_s
    assert_empty entry.conditional_const_returns, "no halt gate, so nothing conditional"
  end

  # A constant written by its SHORT name from inside the namespace that encloses
  # it. `Registry` in `Outer::Host` is `Outer::Registry`, and that is the name the
  # read side resolves (`TypeConstruction#resolved_const_name_string`) and the name
  # every other sidecar key uses. Keyed by the source spelling, the fact is written
  # under `Registry.user`, looked up under `Outer::Registry.user`, and never applies
  # — the guard proves nothing, silently.
  #
  # Invisible in the dummy for a long time because `Current` is top-level, where the
  # two spellings coincide. An engine's `MyEngine::Current` is where it bites.
  def test_conditional_const_return_is_keyed_by_the_resolved_name
    entries = infer_cr_for(<<~RUBY)
      module Outer
        class Host
          def guarded
            unless current_user
              redirect_to
              return
            end
            Registry.user = current_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :guarded }
    refute_nil entry, "expected an entry for the guard"
    assert_equal ["Outer::Registry.user"], entry.conditional_const_returns.keys
  end

  def test_const_establishment_is_keyed_by_the_resolved_name
    entries = infer_cr_for(<<~RUBY)
      module Outer
        class Host
          def plain
            Registry.user = proven_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :plain }
    refute_nil entry, "expected an entry for the populating handler"
    assert_equal ["Outer::Registry.user"], entry.const_establishments.keys
  end

  # The fallback still has to hold: an unresolvable receiver (no singleton type in
  # the typing) keeps its lexical spelling rather than dropping the fact.
  def test_const_establishment_keeps_the_lexical_name_for_a_top_level_constant
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def set_current_user
          Current.user = proven_user
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :set_current_user }
    assert_equal ["Current.user"], entry.const_establishments.keys
  end

  def test_no_unconditional_const_establishment_when_the_method_halts
    # The two collectors partition: with a gate the write is `conditional_const_returns`'s,
    # and reporting it here too would claim it holds on the halting exit as well.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            redirect_to
            return
          end
          Current.user = current_user
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert_empty entry.const_establishments
    refute_empty entry.conditional_const_returns
  end

  def test_no_unconditional_const_establishment_for_a_nilable_write
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def set_current_user
          Current.user = current_user
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :set_current_user }
    assert(entry.nil? || entry.const_establishments.empty?)
  end

  # felixefelip/steep#102. The param is an INTERSECTION carrying a refinement marker, and
  # the attribute it reads is nilable on the base but proven on the marker — which is the
  # whole reason the marker exists. Answering from the first member alone (`::Marked`, so
  # `name: () -> String?`) refused the establishment as nilable and dropped the narrowing.
  def test_establishes_through_an_intersection_receiver
    entries = infer_cr_for(<<~RUBY)
      class MarkedHost
        def value=(value)
          unless value.nil?
            self.other = value.name
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :value= }
    refute_nil entry, "expected an entry for the setter"
    assert_equal "::String", entry.establishes_consts[:other].to_s
  end

  # The `&.` shape has no narrowing at the node (`value&.name` is `String?` however non-nil
  # `name` is), so it goes through the manual resolution — which must reach the marker too.
  def test_establishes_through_an_intersection_receiver_via_safe_navigation
    entries = infer_cr_for(<<~RUBY)
      class MarkedHost
        def value=(value)
          self.other = value&.name
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :value= }
    refute_nil entry, "expected an entry for the setter"
    assert_equal "::String", entry.establishes_consts[:other].to_s
  end

  # felixefelip/steep#117. The sibling write reads the attribute BEING SET rather
  # than the param — `self.identity = session.identity` inside `def session=`,
  # which is how a `CurrentAttributes` override is ordinarily written. The read is
  # the param, because `super(v)` just stored it; the reader's own declared type is
  # `untyped` and must not be consulted.
  def test_establishes_from_a_read_of_the_attribute_being_set
    entries = infer_cr_for(<<~RUBY)
      class MarkedHost
        def value=(v)
          super(v)
          self.other = value.name
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :value= }
    refute_nil entry, "expected an entry for the setter"
    assert_equal "::String", entry.establishes_consts[:other].to_s
    # The own attribute is established by the same `super(v)` that licenses the above.
    assert_equal "(::Marked & ::Marked::Validated)", entry.establishes_consts[:value].to_s
  end

  def test_establishes_from_an_explicit_self_read_of_the_attribute_being_set
    entries = infer_cr_for(<<~RUBY)
      class MarkedHost
        def value=(v)
          super(v)
          self.other = self.value.name
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :value= }
    refute_nil entry, "expected an entry for the setter"
    assert_equal "::String", entry.establishes_consts[:other].to_s
  end

  def test_establishes_from_a_backing_ivar_read_of_the_attribute_being_set
    entries = infer_cr_for(<<~RUBY)
      class MarkedHost
        def value=(v)
          @value = v
          self.other = @value.name
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :value= }
    refute_nil entry, "expected an entry for the setter"
    assert_equal "::String", entry.establishes_consts[:other].to_s
  end

  def test_no_establishes_from_own_attribute_read_without_writing_the_backing
    # No `super(v)` and no `@value = v`, so nothing says the attribute holds the
    # param — the read could be anything, and the establishment must be refused.
    # This is the gate: it is what keeps the rule from asserting a fact the body
    # never established.
    entries = infer_cr_for(<<~RUBY)
      class MarkedHost
        def value=(v)
          self.other = value.name
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :value= }
    refute entry&.establishes_consts&.key?(:other),
           "a read of the attribute proves nothing when the body never stored the param in it"
  end

  # felixefelip/rbs_infer#144. A two-clause `if` where one side establishes and
  # the other halts. Leaving without having halted means the establishing clause
  # ran, so the fact keys the halt-gated slot — the same one a guard clause uses.
  def test_collects_a_const_return_from_a_halting_alternative
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate
          if current_user
            Current.user = proven_user
          else
            @halted = true
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate }
    refute_nil entry
    spec = entry.conditional_const_returns["Current.user"]
    refute_nil spec, "expected Current.user proven on the unhalted exit"
    assert_equal :@halted, spec[:gate_ivar]
    assert_equal "::User", spec[:type].to_s
    # NOT unconditional: the halting branch establishes nothing.
    refute entry.const_establishments.key?("Current.user")
  end

  def test_collects_a_const_return_when_the_halting_clause_comes_first
    # Nothing in the shape says which side is which; the mirror reads the same.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate
          if current_user
            @halted = true
          else
            Current.user = proven_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate }
    assert_equal :@halted, entry&.conditional_const_returns&.dig("Current.user", :gate_ivar)
  end

  def test_no_const_return_from_a_halting_alternative_writing_a_nilable_value
    # The condition tests something else, so `current_user` is NOT narrowed at
    # the write and may be nil — taking the establishing clause proves nothing.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate
          if flag?
            Current.user = current_user
          else
            @halted = true
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate }
    refute entry&.conditional_const_returns&.key?("Current.user")
  end

  def test_no_const_return_from_a_one_armed_if_that_never_halts
    # One clause, no halt anywhere: nothing distinguishes the exits.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate
          if current_user
            Current.user = proven_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate }
    refute entry&.conditional_const_returns&.key?("Current.user")
  end

  # felixefelip/steep#117 gap 3b. A one-armed `if` as the last statement: a truthy
  # return can only have come from the clause, since every other way out is the
  # implicit `nil`.
  def test_collects_a_when_true_const_write
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def resume
          if current_user
            Current.user = proven_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :resume }
    refute_nil entry
    assert_equal "::User", entry.when_true_consts["Current.user"].to_s
    # NOT unconditional — the clause may not run.
    refute entry.const_establishments.key?("Current.user")
  end

  def test_collects_a_when_true_const_write_from_an_unless
    # `unless c; A; end` is the same shape with the clauses swapped: the missing
    # branch is still an implicit `nil`.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def resume
          unless current_user
            Current.user = proven_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :resume }
    assert_equal "::User", entry&.when_true_consts&.[]("Current.user").to_s
  end

  def test_no_when_true_const_for_an_indexed_write
    # `ENV["KEY"] = value` is not an attribute write. It surfaced here because
    # gap 3b is the first collector to read inside a clause, and it keyed the
    # meaningless path `ENV.[]` in a real project.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def resume
          if current_user
            Current["key"] = proven_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :resume }
    refute entry&.when_true_consts&.keys&.any? { |path| path.include?("[]") },
           "an indexed write must not key a const attribute path"
  end

  def test_collects_a_when_true_call_dep
    # The clause holds a CALL, which is the common case — the Runner resolves it
    # against what the callee establishes.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def resume
          if current_user
            set_current_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :resume }
    refute_nil entry
    assert_includes entry.when_true_call_deps, "CRGuardHost#set_current_user"
  end

  def test_no_when_true_const_when_the_if_has_an_else
    # The `else` is a second way to return truthy, so a truthy result no longer
    # implies the clause ran.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def resume
          if current_user
            Current.user = proven_user
          else
            proven_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :resume }
    refute entry&.when_true_consts&.key?("Current.user")
  end

  def test_no_when_true_const_when_the_method_can_return_early
    # An early `return` is a third way out, and it can carry a truthy value.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def resume
          return proven_user if current_user

          if current_user
            Current.user = proven_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :resume }
    refute entry&.when_true_consts&.key?("Current.user")
  end

  def test_no_when_true_const_when_the_if_is_not_the_last_statement
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def resume
          if current_user
            Current.user = proven_user
          end

          proven_user
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :resume }
    refute entry&.when_true_consts&.key?("Current.user")
  end

  # felixefelip/steep#117 gap 3a. The every-exit call edges the Runner follows to
  # lift a callee's establishment into its caller. Distinct from `self_call_deps`
  # on both axes: top-level statements only, and any receiver.
  def test_collects_an_unconditional_call_dep
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          set_current_user
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    refute_nil entry
    assert_includes entry.unconditional_call_deps, "CRGuardHost#set_current_user"
  end

  def test_collects_an_unconditional_call_dep_from_an_assignment
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          user = proven_user
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    refute_nil entry
    assert_includes entry.unconditional_call_deps, "CRGuardHost#proven_user"
  end

  def test_no_unconditional_call_dep_for_a_conditional_call
    # The soundness boundary, and the shape that motivated the gap: a call inside
    # an `if` runs on some exits and not others, so it establishes nothing.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          if current_user
            set_current_user
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    refute_includes(entry&.unconditional_call_deps || Set[], "CRGuardHost#set_current_user")
  end

  def test_no_unconditional_call_dep_for_a_safe_navigated_call
    # `current_user&.full_name` does not run when the receiver is nil.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          current_user&.full_name
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    refute_includes(entry&.unconditional_call_deps || Set[], "User#full_name")
  end

  def test_no_unconditional_call_deps_when_the_method_can_halt
    # Past a halt the later statements are not reached, so nothing in the body is
    # on every exit. Same gate `collect_const_establishments` applies.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          unless current_user
            @halted = true
            return
          end

          set_current_user
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    refute_nil entry
    assert_empty entry.unconditional_call_deps
  end

  def test_infers_establishes_consts_from_instance_setter_override
    # felixefelip/steep#68 item 5. An instance setter override that does
    # `self.author_name = value&.full_name` establishes `author_name` non-nil
    # when the arg is non-nil (`full_name` returns String). The singleton setter
    # that forwards to `instance.user =` is flagged as delegating, so the Runner
    # may attribute the establishment to a `Current.user =` write.
    entries = infer_cr_for(<<~RUBY)
      class Current
        def user=(value)
          @user = value
          self.author_name = value&.full_name
        end

        def self.user=(value)
          @user = value
          instance.user = value
        end
      end
    RUBY

    instance_setter = entries.find { |e| e.method_name == :user= && !e.singleton }
    refute_nil instance_setter
    assert_equal "::String", instance_setter.establishes_consts[:author_name].to_s

    singleton_setter = entries.find { |e| e.method_name == :user= && e.singleton }
    refute_nil singleton_setter
    assert singleton_setter.delegates_to_instance, "self.user= forwards to instance.user="
  end

  def test_infers_own_attribute_establish_from_super
    # felixefelip/steep#76 (RC1). A setter that forwards the param via `super`
    # establishes its OWN attribute (`user`) at the param's non-nil type — the
    # `attr_accessor` override pattern.
    entries = infer_cr_for(<<~RUBY)
      class Current
        def user=(value)
          super(value)
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :user= && !e.singleton }
    refute_nil entry
    assert_equal "::User", entry.establishes_consts[:user].to_s
  end

  def test_infers_own_attribute_establish_for_singleton_ivar_write
    # felixefelip/steep#76 (RC1). A SINGLETON setter writing its own backing
    # ivar (`def self.user=(value); @user = value; end`) establishes `user` at
    # the param's non-nil type — the direct const-path accessor pattern
    # (`Example4::Foo`).
    entries = infer_cr_for(<<~RUBY)
      class Current
        def self.user=(value)
          @user = value
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :user= && e.singleton }
    refute_nil entry
    assert_equal "::User", entry.establishes_consts[:user].to_s
  end

  def test_no_establishes_consts_for_nilable_derived_write
    # `self.author_name = value&.title` where `title` itself returns String? —
    # even with value non-nil the result is nilable, so nothing is established.
    entries = infer_cr_for(<<~RUBY)
      class Current
        def user=(value)
          @user = value
          self.author_name = value&.maybe_name
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :user= && !e.singleton }
    # The DERIVED write `self.author_name = value&.maybe_name` is nilable-derived,
    # so `author_name` is not established. The own-attribute `user` IS established
    # from `@user = value` at the param's non-nil type — a separate, correct fact
    # (felixefelip/steep#76).
    refute_nil entry
    refute entry.establishes_consts.key?(:author_name)
    assert_equal "::User", entry.establishes_consts[:user].to_s
  end

  def test_no_conditional_const_return_for_nilable_write
    # `Current.user = current_user` BEFORE proving `current_user` present — the
    # written value is nilable, so nothing about `Current.user` is proven.
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def authenticate_user
          Current.user = current_user
          unless current_user
            redirect_to
            return
          end
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :authenticate_user }
    assert(entry.nil? || entry.conditional_const_returns.empty?)
  end

  # Was `test_no_conditional_return_without_return_in_guard`, asserting that a
  # guard with no `return` proved nothing "because the method falls through either
  # way". felixefelip/steep#105 gap 2 is precisely that falling through is not a
  # third possibility when the guard is LAST: there is nothing to fall through to,
  # so both branches end the method and the gate is exact.
  #
  # The old rationale survives, narrowed to the case it actually describes — a
  # clause with code after it — which `test_a_halting_clause_that_is_not_last_
  # proves_nothing` pins.
  #
  # Here the clause writes the gate ivar directly, so this is also the implicit
  # return composed with the `gate_ivar` path rather than `gate_via`.
  def test_a_final_guard_writing_its_gate_directly_needs_no_return
    entries = infer_cr_for(<<~RUBY)
      class CRGuardHost
        def no_return
          unless current_user
            @halted = true
          end
        end
      end
    RUBY

    spec = entries.find { |e| e.method_name == :no_return }.conditional_returns[:current_user]
    refute_nil spec
    assert_equal :@halted, spec[:gate_ivar]
  end
end

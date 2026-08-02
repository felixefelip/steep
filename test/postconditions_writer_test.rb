require_relative "test_helper"

class PostconditionsWriterTest < Minitest::Test
  Postconditions = Steep::Postconditions
  Writer = Postconditions::Writer
  InferredEntry = Postconditions::InferredEntry
  Store = Postconditions::Store

  def build_entry(class_name:, method_name:, ivars:, singleton: false, self_type_string: nil)
    InferredEntry.new(
      class_name: class_name,
      method_name: method_name,
      singleton: singleton,
      ivars: ivars,
      self_type_string: self_type_string
    )
  end

  def test_dump_serializes_unconditional_ivars
    entry = build_entry(
      class_name: "PCSetterController",
      method_name: :set_company,
      ivars: { :"@company" => Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::Company").absolute!, args: []) }
    )

    yaml = Writer.dump([entry])
    raw = YAML.safe_load(yaml)

    # Round-trip back through the loader so the test asserts on parsed
    # structure rather than YAML string formatting (which can vary by
    # Psych version).
    store = Store.from_hash(raw, source: "<test>")
    parsed_entry = store.lookup_instance("PCSetterController", :set_company)

    refute_nil parsed_entry, "expected entry to round-trip through the loader"
    refute_nil parsed_entry.unconditional, "expected unconditional branch to be present"
    assert_equal({ :"@company" => "::Company" }, parsed_entry.unconditional.ivar_type_strings)
  end

  def test_dump_sorts_entries_for_deterministic_output
    zeta = build_entry(
      class_name: "ZetaCtrl",
      method_name: :a,
      ivars: { :"@x" => Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::Integer").absolute!, args: []) }
    )
    alpha = build_entry(
      class_name: "AlphaCtrl",
      method_name: :b,
      ivars: { :"@y" => Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::String").absolute!, args: []) }
    )

    yaml = Writer.dump([zeta, alpha])
    alpha_pos = yaml.index("AlphaCtrl") or flunk("AlphaCtrl not found")
    zeta_pos = yaml.index("ZetaCtrl") or flunk("ZetaCtrl not found")
    assert alpha_pos < zeta_pos, "expected AlphaCtrl to be emitted before ZetaCtrl for deterministic output"
  end

  def test_dump_serializes_unconditional_self_when_provided
    # An inferred entry carrying `self_type_string` round-trips through
    # the loader and surfaces on `parsed_entry.unconditional.self_type_string`.
    # Ivars and self coexist in the same `unconditional:` block.
    entry = build_entry(
      class_name: "PCSetterController",
      method_name: :set_company,
      ivars: { :"@company" => Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::Company").absolute!, args: []) },
      self_type_string: "::PCSetterController & ::PCSetterController::AfterSetCompany"
    )

    yaml = Writer.dump([entry])
    raw = YAML.safe_load(yaml)

    store = Store.from_hash(raw, source: "<test>")
    parsed_entry = store.lookup_instance("PCSetterController", :set_company)

    refute_nil parsed_entry
    refute_nil parsed_entry.unconditional
    assert_equal "::PCSetterController & ::PCSetterController::AfterSetCompany",
                 parsed_entry.unconditional.self_type_string
    assert_equal({ :"@company" => "::Company" }, parsed_entry.unconditional.ivar_type_strings)
  end

  def test_dump_omits_self_slot_when_absent
    # When `self_type_string` is nil/empty the writer must NOT emit a
    # `self:` key — otherwise the loader sees an empty string and
    # `Branch.parse` would treat it as content-less but still build a
    # branch. Cleaner output, fewer empty keys.
    entry = build_entry(
      class_name: "Foo",
      method_name: :bar,
      ivars: { :"@x" => Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::Integer").absolute!, args: []) }
    )

    yaml = Writer.dump([entry])
    refute yaml.include?("self:"), "expected no `self:` key when self_type_string is nil, got:\n#{yaml}"
  end

  def test_dump_serializes_ivar_keys_in_alphabetical_order
    entry = build_entry(
      class_name: "MultiIvar",
      method_name: :setup,
      ivars: {
        :"@zeta" => Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::String").absolute!, args: []),
        :"@alpha" => Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::Integer").absolute!, args: [])
      }
    )

    yaml = Writer.dump([entry])

    alpha_pos = yaml.index("@alpha") or flunk("@alpha not found")
    zeta_pos = yaml.index("@zeta") or flunk("@zeta not found")
    assert alpha_pos < zeta_pos, "expected @alpha to be emitted before @zeta"
  end

  def test_dump_serializes_returns_establishes_without_ivars
    # A `build`-style entry establishes a return attribute but sets no
    # ivar. The `unconditional` branch must still be emitted, carrying
    # only `returns.establishes`, and round-trip through the loader.
    entry = InferredEntry.new(
      class_name: "RVFactory",
      method_name: :build,
      singleton: false,
      returns_establishes: [:post, :user]
    )

    yaml = Writer.dump([entry])
    raw = YAML.safe_load(yaml)
    store = Store.from_hash(raw, source: "<test>")
    parsed = store.lookup_instance("RVFactory", :build)

    refute_nil parsed, "expected build entry to round-trip"
    refute_nil parsed.unconditional, "expected unconditional branch with only returns"
    assert_empty parsed.unconditional.ivar_type_strings
    assert_equal [:post, :user], parsed.unconditional.returns_establishes.sort
  end

  # felixefelip/rbs_infer#144 stage 2. The fact belongs to the truthy branch — it
  # is only ever true of a truthy exit — and it is written although no consumer
  # reads it back yet (that is stage 3), on the same grounds as the `consts` in
  # that branch: a fact nobody can see is a fact nobody can check.
  def test_dump_serializes_block_truthiness_on_the_truthy_branch
    entry = InferredEntry.new(
      class_name: "BTToken",
      method_name: :authenticate,
      singleton: false,
      when_true_block_truthy: true
    )

    raw = YAML.safe_load(Writer.dump([entry]))
    row = raw["postconditions"].find { |r| r["class"] == "BTToken" }

    refute_nil row, "expected the entry to be emitted"
    assert_equal({ "block_truthy" => true }, row["when_true"])
  end

  def test_dump_omits_block_truthiness_when_it_was_not_proven
    entry = InferredEntry.new(
      class_name: "BTToken",
      method_name: :forwards,
      singleton: false,
      may_write_ivars: Set[:@x]
    )

    raw = YAML.safe_load(Writer.dump([entry]))
    row = raw["postconditions"].find { |r| r["class"] == "BTToken" }

    refute row.key?("when_true"), "an unproven fact is not a branch"
  end
end

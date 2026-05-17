require_relative "test_helper"

class PostconditionsTest < Minitest::Test
  Postconditions = Steep::Postconditions

  def test_empty_store
    store = Postconditions::Store.empty
    assert_predicate store, :empty?
    assert_nil store.lookup_instance("Foo", :bar)
  end

  def test_parses_instance_entry
    raw = {
      "postconditions" => [
        {
          "class" => "OrderImport",
          "method" => "shipment?",
          "when_true" => { "self" => "OrderImport & OrderImport::ValidatedAsShipment" }
        }
      ]
    }
    store = Postconditions::Store.from_hash(raw, source: "<test>")
    entry = store.lookup_instance("OrderImport", :shipment?)

    refute_nil entry
    assert_equal "OrderImport", entry.class_name
    assert_equal :shipment?, entry.method_name
    refute_nil entry.when_true
    assert_nil entry.when_false
    assert_equal "OrderImport & OrderImport::ValidatedAsShipment", entry.when_true.self_type_string
  end

  def test_parses_both_branches
    raw = {
      "postconditions" => [
        {
          "class" => "Foo",
          "method" => "valid?",
          "when_true" => { "self" => "Foo & Foo::Validated" },
          "when_false" => { "self" => "Foo" }
        }
      ]
    }
    store = Postconditions::Store.from_hash(raw, source: "<test>")
    entry = store.lookup_instance("Foo", :valid?)

    refute_nil entry.when_true
    refute_nil entry.when_false
  end

  def test_lookup_absolute_type_name_strips_double_colon
    raw = { "postconditions" => [{ "class" => "Foo", "method" => "ok?", "when_true" => { "self" => "Foo" } }] }
    store = Postconditions::Store.from_hash(raw, source: "<test>")
    refute_nil store.lookup_instance("::Foo", :ok?)
    refute_nil store.lookup_instance("Foo", :ok?)
  end

  def test_duplicate_entries_first_wins
    raw = {
      "postconditions" => [
        { "class" => "X", "method" => "go?", "when_true" => { "self" => "X & X::A" } },
        { "class" => "X", "method" => "go?", "when_true" => { "self" => "X & X::B" } }
      ]
    }
    store = Postconditions::Store.from_hash(raw, source: "<test>")
    entry = store.lookup_instance("X", :go?)
    assert_equal "X & X::A", entry.when_true.self_type_string
  end

  def test_skips_entries_missing_both_branches
    raw = {
      "postconditions" => [
        { "class" => "X", "method" => "go?" }
      ]
    }
    store = Postconditions::Store.from_hash(raw, source: "<test>")
    assert_predicate store, :empty?
  end

  def test_branch_rbs_type_caches_parse
    branch = Postconditions::Branch.new(self_type_string: "Foo & Foo::Validated")
    parsed = branch.rbs_type
    assert_kind_of RBS::Types::Intersection, parsed
    assert_same parsed, branch.rbs_type
  end

  def test_branch_rbs_type_returns_nil_on_invalid_string
    branch = Postconditions::Branch.new(self_type_string: "@@invalid syntax")
    assert_nil branch.rbs_type
  end
end

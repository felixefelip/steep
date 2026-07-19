require_relative "test_helper"

# felixefelip/rbs_infer#71 (piece 2 — the write-site wiring). A singleton setter
# `Const.user = <non-nil>` whose `unconditional.establishes_consts` postcondition
# names a sibling attribute proves `Const.<attr>` non-nil for the rest of the
# frame — the memoized-singleton delegation (`Example3::Foo`: `Foo.user = user`
# makes `Foo.name` non-nil because `def user=` writes `name`).
#
# This exercises ONLY the consumption side: the sidecar is hand-written here.
# Inferring/serializing it (generalizing the `.instance` delegation recognition
# to a memoized `foo_instance`) is the follow-up piece.
class PostconditionsConstEstablishesTest < Minitest::Test
  include TestHelper
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  Postconditions = Steep::Postconditions

  RBS = <<~RBS
    class Foo
      def self.name: () -> String?
      def self.user=: (String value) -> void
    end
  RBS

  # `Foo.user=` establishes `Foo.name` non-nil.
  def establishes_name_store
    Postconditions::Store.from_hash(
      {
        "version" => 1,
        "postconditions" => [
          {
            "class" => "Foo",
            "method" => "user=",
            "unconditional" => {
              "establishes_consts" => { "name" => "::String" }
            }
          }
        ]
      },
      source: "<test>"
    )
  end

  # The `(send (const nil :Foo) :name)` read node — here the trailing statement.
  def last_foo_name_type(source, typing)
    body = source.node # begin(...) or the single trailing node
    node = body.type == :begin ? body.children.last : body
    typing.type_of(node: node)
  end

  def test_write_establishes_sibling_const_non_nil
    with_checker(RBS) do |checker|
      source = parse_ruby(<<~RUBY)
        Foo.user = "x"
        Foo.name
      RUBY

      with_standard_construction(checker, source, postconditions: establishes_name_store) do |construction, typing|
        construction.synthesize(source.node)
        t = last_foo_name_type(source, typing)
        assert_equal "::String", t.to_s,
                     "after `Foo.user = <non-nil>`, the establishes_consts fact narrows `Foo.name` to non-nil"
      end
    end
  end

  def test_no_sidecar_leaves_const_read_nilable
    with_checker(RBS) do |checker|
      source = parse_ruby(<<~RUBY)
        Foo.user = "x"
        Foo.name
      RUBY

      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)
        t = last_foo_name_type(source, typing)
        assert_equal "(::String | nil)", t.to_s,
                     "without the postcondition, `Foo.name` stays nilable"
      end
    end
  end

  def test_nil_write_does_not_establish
    with_checker(RBS) do |checker|
      # `Foo.user = nil` would be a type error against `(String)`, but the point
      # is the establishment gate: a nilable RHS proves nothing. Use a nilable
      # local so the write itself type-checks against a widened setter.
      source = parse_ruby(<<~RUBY)
        # @type var maybe: ::String?
        maybe = nil
        Foo.user = maybe
        Foo.name
      RUBY

      with_standard_construction(checker, source, postconditions: establishes_name_store) do |construction, typing|
        construction.synthesize(source.node)
        t = last_foo_name_type(source, typing)
        assert_equal "(::String | nil)", t.to_s,
                     "a nilable RHS must NOT establish the sibling const non-nil"
      end
    end
  end
end

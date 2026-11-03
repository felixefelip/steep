require_relative "test_helper"
require_relative "specializations_project_helper"

class ArrayTupleFoldsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def types_of(bodies, reopen: "")
    in_tmpdir do
      write("sig/p.rbs", "class P\n#{bodies.keys.map { |name| "  def #{name}: (:fr locale) -> untyped\n" }.join}end\n")
      write("app/p.rb", "#{reopen}class P\n#{bodies.map { |name, body| "  def #{name}(locale)\n    #{body.gsub("\n", "\n    ")}\n  end\n" }.join}end\n")
      return body_types(setup_project, current_dir + "app/p.rb")
    end
  end

  def test_uniq_compact_and_difference_fold_over_a_tuple_of_literals
    types = types_of({
      "uniq" => "[locale, :en, locale].uniq",
      "compact" => "[locale, nil, :en].compact",
      "difference" => "[locale, :en, :de] - [:en]",
      "chained" => "([locale, :en] + [locale]).uniq - [:de]",
      "accumulated" => "result = []\nresult << locale\nresult << :en\nresult << locale\nresult.uniq.compact"
    })

    assert_equal "[:fr, :en]", types.fetch("uniq")
    assert_equal "[:fr, :en]", types.fetch("compact")
    assert_equal "[:fr, :de]", types.fetch("difference")
    assert_equal "[:fr, :en]", types.fetch("chained")
    assert_equal "[:fr, :en]", types.fetch("accumulated")
  end

  def test_length_and_concat_fold_over_a_tuple_and_integers_compare
    types = types_of({
      "length" => "[locale, :en].length",
      "size" => "[locale].size",
      "concat" => "[locale].concat([], [locale])",
      "compared" => "[[locale].length > 1, 1 < 2, 2 >= 2, 3 <= 2]",
      "branch" => "segs = [locale]\nsegs.length > 1 ? :many : nil"
    })

    assert_equal "2", types.fetch("length")
    assert_equal "1", types.fetch("size")
    assert_equal "[:fr, :fr]", types.fetch("concat")
    assert_equal "[false, true, true, false]", types.fetch("compared")
    assert_equal "nil", types.fetch("branch")
  end

  def test_declines_a_length_or_comparison_the_project_redefines
    reopen = "class Array\n  def length = 0\nend\nclass Integer\n  def >(other) = true\nend\n"
    types = types_of({ "length" => "[locale].length", "compared" => "1 > 2" }, reopen: reopen)

    assert_equal "::Integer", types.fetch("length")
    assert_equal "bool", types.fetch("compared")
  end

  def test_declines_elements_told_apart_by_a_call_the_fold_does_not_watch
    types = types_of({ "patterns" => "[/a/, /a/].uniq", "unknown" => "[locale, :en] - [Object.new]" })

    refute_match(/\A\[/, types.fetch("patterns"))
    refute_match(/\A\[/, types.fetch("unknown"))
  end

  def test_declines_where_the_project_redefines_how_elements_compare
    types = types_of({ "uniq" => "[locale, :en, locale].uniq", "difference" => "[locale, :en] - [:en]" }, reopen: "class Symbol\n  def hash = 0\nend\n")

    refute_match(/\A\[/, types.fetch("uniq"))
    refute_match(/\A\[/, types.fetch("difference"))
  end

  def test_kernel_array_folds_a_literal_nil_or_a_tuple
    types = types_of({
      "tuple" => "Array([locale, :en])",
      "literal" => "result = []\nArray(locale).each { |tag| result << tag }\nresult.join(\",\")",
      "nil" => "result = [:x]\nArray(nil).each { |tag| result << tag }\nresult.join(\",\")"
    })

    assert_equal "[:fr, :en]", types.fetch("tuple")
    assert_equal '"fr"', types.fetch("literal")
    assert_equal '"x"', types.fetch("nil")
  end

  def test_kernel_array_declines_an_argument_it_would_convert_by_an_unwatched_call
    types = types_of({ "integer" => "result = []\nArray(1).each { |tag| result << tag }\nresult" })

    refute_equal "[1]", types.fetch("integer")
  end

  def test_kernel_array_declines_where_the_project_redefines_the_conversion
    looped = ->(argument) { { "looped" => "result = [:x]\nArray(#{argument}).each { |tag| result << tag }\nresult.join(\",\")" } }

    refute_equal '"x,fr"', types_of(looped.(:locale), reopen: "class Symbol\n  def to_a = [:y]\nend\n").fetch("looped")
    refute_equal '"x"', types_of(looped.(:nil), reopen: "class NilClass\n  def to_a = [:y]\nend\n").fetch("looped")
  end
end

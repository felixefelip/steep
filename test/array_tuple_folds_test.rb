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
end

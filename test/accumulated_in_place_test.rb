require_relative "test_helper"
require_relative "specializations_project_helper"

class AccumulatedInPlaceTest < Minitest::Test
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

  def test_push_concat_and_plus_assign_copy_elements_into_the_local
    types = types_of({
      "push" => "result = []\nresult.push(locale, :en)\nresult.join(\",\")",
      "splat" => "result = [:x]\nresult.push(*[locale, :en])\nresult.join(\",\")",
      "concat" => "result = []\nresult.concat([locale], [:en])\nresult.join(\",\")",
      "plus_assign" => "result = [:x]\nresult += [locale]\nresult.join(\",\")",
      "returned" => "result = []\nresult += [locale, :en]\nresult"
    })

    assert_equal '"fr,en"', types.fetch("push")
    assert_equal '"x,fr,en"', types.fetch("splat")
    assert_equal '"fr,en"', types.fetch("concat")
    assert_equal '"x,fr"', types.fetch("plus_assign")
    assert_equal "[:fr, :en]", types.fetch("returned")
  end

  def test_uniq_and_compact_in_place_reshape_what_the_local_holds
    types = types_of({
      "uniq" => "result = []\nresult << locale\nresult += [:en, locale]\nresult.uniq!\nresult",
      "compact" => "result = [nil]\nresult << locale\nresult.compact!\nresult.join(\",\")",
      "unchanged" => "result = [locale]\nresult.uniq!\nresult"
    })

    assert_equal "[:fr, :en]", types.fetch("uniq")
    assert_equal '"fr"', types.fetch("compact")
    assert_equal "[:fr]", types.fetch("unchanged")
  end

  def test_a_loop_splices_once_per_element
    types = types_of({
      "plus_assign" => "result = []\n[:fr, :en].each { |tag| result += [tag] }\nresult.join(\",\")",
      "splat" => "result = []\n[:fr, :en].each { |tag| result.push(*[tag, tag]) }\nresult.uniq!\nresult"
    })

    assert_equal '"fr,en"', types.fetch("plus_assign")
    assert_equal "[:fr, :en]", types.fetch("splat")
  end

  def test_declines_a_spliced_array_whose_elements_are_not_known
    types = types_of({ "unknown" => "result = [locale]\nresult.concat([Object.new])\nresult" })

    refute_match(/\A\[/, types.fetch("unknown"))
  end

  def test_declines_where_the_project_redefines_the_in_place_method
    types = types_of(
      { "uniq" => "result = [locale, locale]\nresult.uniq!\nresult", "concat" => "result = []\nresult.concat([locale])\nresult.join(\",\")" },
      reopen: "class Array\n  def uniq! = nil\n  def concat(*) = self\nend\n"
    )

    refute_match(/\A\[/, types.fetch("uniq"))
    refute_match(/\A"/, types.fetch("concat"))
  end
end

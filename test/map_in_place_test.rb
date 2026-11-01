require_relative "test_helper"
require_relative "specializations_project_helper"

class MapInPlaceTest < Minitest::Test
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

  def test_the_value_of_map_bang_is_folded_per_element
    types = types_of({
      "literal" => "[locale.to_s, \"en\"].map! { |tag| tag.upcase }",
      "chained" => "([locale.to_s, \"en\", \"de\"].map! { |tag| tag.upcase } - [\"EN\"]).join(\",\")",
      "collect" => "[locale.to_s, \"de\"].collect! { |tag| tag.upcase }"
    })

    assert_equal '["FR", "EN"]', types.fetch("literal")
    assert_equal '"FR,DE"', types.fetch("chained")
    assert_equal '["FR", "DE"]', types.fetch("collect")
  end

  def test_map_bang_on_an_accumulated_local_changes_what_it_holds
    types = types_of({
      "returned" => "result = []\nresult << locale\nresult << :en\nresult.map! { |tag| tag.to_s.upcase.to_sym }\nresult",
      "joined" => "result = [locale, :en]\nresult.map! { |tag| tag.to_s.upcase.to_sym }\nresult.join(\",\")",
      "then_pushed" => "result = [locale, :en]\nresult.map! { |tag| tag.to_s.upcase.to_sym }\nresult << :x\nresult.join(\",\")"
    })

    assert_equal '[:FR, :EN]', types.fetch("returned")
    assert_equal '"FR,EN"', types.fetch("joined")
    assert_equal '"FR,EN,x"', types.fetch("then_pushed")
  end

  def test_declines_a_block_that_names_a_followed_local
    types = types_of({
      "named" => "result = [locale, :en]\nresult.map! { |tag| result.pop\ntag }\nresult",
      "other" => "other = [:x]\nresult = [locale, :en]\nresult.map! { |tag| other << tag\ntag }\nother.join(\",\")"
    })

    assert_equal "::Array[(:fr | ::Symbol)]", types.fetch("named")
    assert_equal "::String", types.fetch("other")
  end

  def test_declines_a_map_bang_made_by_a_method_the_local_is_handed_to
    in_tmpdir do
      write("sig/p.rbs", "class P\n  def handed: (:fr locale) -> untyped\n  def shout: (Array[Symbol] parts) -> untyped\nend\n")
      write("app/p.rb", "class P\n  def handed(locale)\n    result = [locale, :en]\n    shout(result)\n    result\n  end\n\n  def shout(parts)\n    parts.map! { |tag| tag.to_s.upcase.to_sym }\n  end\nend\n")

      assert_equal "::Array[(:fr | ::Symbol)]", body_types(setup_project, current_dir + "app/p.rb").fetch("handed")
    end
  end

  def test_declines_where_the_project_redefines_map_bang
    types = types_of(
      { "value" => "[locale, :en].map! { |tag| tag.to_s.upcase.to_sym }", "local" => "result = [locale, :en]\nresult.map! { |tag| tag.to_s.upcase.to_sym }\nresult" },
      reopen: "class Array\n  def map! = self\nend\n"
    )

    refute_equal "[:FR, :EN]", types.fetch("value")
    refute_match(/\A\[/, types.fetch("local"))
  end
end

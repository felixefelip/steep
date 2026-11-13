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

  def test_scan_with_a_block_runs_once_per_match_with_the_match_globals_set
    types = types_of({
      "pre_match" => "result = []\n\"Example::Post\".scan(/::|$/) { result << \"\#{$`}::Comment\" }\nresult",
      "post_match" => "result = []\n\"a-b\".scan(/\\w/) { |m| result << \"\#{m}\#{$'}\" }\nresult",
      "groups" => "result = []\n\"a1b2\".scan(/(\\w)(\\d)/) { |pair| result << \"\#{$1}\#{$2}\#{$&}\" }\nresult",
      "not_literal" => "result = []\n\"\#{rand}\".scan(/./) { result << $` }\nresult"
    })

    assert_equal '["Example::Comment", "Example::Post::Comment"]', types.fetch("pre_match")
    assert_equal '["a-b", "b"]', types.fetch("post_match")
    assert_equal '["a1a1", "b2b2"]', types.fetch("groups")
    assert_equal "::Array[untyped]", types.fetch("not_literal")
  end

  def test_a_scan_the_project_replaces_is_not_expanded
    types = types_of({ "scan" => "result = []\n\"ab\".scan(/./) { |m| result << m }\nresult" }, reopen: "class String\n  def scan(pattern) = super\nend\n")

    assert_equal "::Array[untyped]", types.fetch("scan")
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

  def test_each_local_a_multiple_assignment_gives_an_array_is_followed
    types = types_of({
      "both" => "result, other = [], [:x]\nresult << locale\nother << :y\n\"\#{result.join(\",\")}/\#{other.join(\",\")}\"",
      "loop" => "result, other = [], []\n[:fr, :en].each { |tag| result << tag }\nresult.join(\",\")",
      "aliased" => "result, other = [], []\nother = result\nother << locale\nresult.join(\",\")",
      "splat" => "result, *other = [], []\nresult << locale\nresult.join(\",\")"
    })

    assert_equal '"fr/x,y"', types.fetch("both")
    assert_equal '"fr,en"', types.fetch("loop")
    assert_equal "::String", types.fetch("aliased")
    assert_equal "::String", types.fetch("splat")
  end

  def test_a_splat_or_plus_of_the_local_reads_its_elements
    types = types_of({
      "splat" => "result = []\nresult << locale\n[\"a\", *result, \"z\"].join(\";\")",
      "plus" => "result = []\nresult << locale\n([\"a\"] + result + [\"z\"]).join(\";\")",
      "loop" => "result = []\n[:x, :y].each { |tag| result << tag }\n[*result, locale].join(\";\")",
      "literal" => "[\"a\", *[locale, :b]].join(\";\")",
      "held_whole" => "result = []\nresult << locale\nother = [result]\nother.first << :b\nresult.join(\";\")",
      "copied" => "result = []\nresult << locale\ncopy = [*result]\nresult << :b\ncopy.join(\";\")"
    })

    assert_equal '"a;fr;z"', types.fetch("splat")
    assert_equal '"a;fr;z"', types.fetch("plus")
    assert_equal '"x;y;fr"', types.fetch("loop")
    assert_equal '"a;fr;b"', types.fetch("literal")
    assert_equal "::String", types.fetch("held_whole")
    assert_equal "::String", types.fetch("copied")
  end

  def test_a_loop_splices_once_per_element
    types = types_of({
      "plus_assign" => "result = []\n[:fr, :en].each { |tag| result += [tag] }\nresult.join(\",\")",
      "splat" => "result = []\n[:fr, :en].each { |tag| result.push(*[tag, tag]) }\nresult.uniq!\nresult"
    })

    assert_equal '"fr,en"', types.fetch("plus_assign")
    assert_equal "[:fr, :en]", types.fetch("splat")
  end

  def test_a_loop_over_a_literal_that_holds_a_parameter_counts_its_passes
    types = types_of({
      "push" => "result = []\n[locale, :en].each { |tag| result << tag }\nresult.join(\",\")",
      "aliased" => "other = [:x]\nresult = []\n[other].each { |tag| tag << :y\nresult << :z }\nother.join(\",\")"
    })

    assert_equal '"fr,en"', types.fetch("push")
    refute_equal '"x"', types.fetch("aliased")
  end

  def test_a_local_spliced_into_another_is_read_where_the_push_reads_it
    types = types_of({
      "plus_assign" => "parts = [:en]\nresult = [locale]\nresult += parts\nresult",
      "splat" => "parts = [:en]\nresult = []\nresult << locale\nresult.push(*parts)\nresult",
      "concat" => "parts = [:en]\nresult = []\nresult << locale\nresult.concat(parts)\nresult",
      "changed_after" => "parts = [:en]\nresult = [locale]\nresult += parts\nparts << :x\nresult",
      "in_a_loop" => "result = []\n[locale, :en].each do |tag|\n  parts = [tag]\n  result += parts\nend\nresult"
    })

    assert_equal "[:fr, :en]", types.fetch("plus_assign")
    assert_equal "[:fr, :en]", types.fetch("splat")
    assert_equal "[:fr, :en]", types.fetch("concat")
    assert_equal "[:fr, :en]", types.fetch("changed_after")
    assert_equal "[:fr, :en]", types.fetch("in_a_loop")
  end

  def test_declines_a_spliced_local_handed_elsewhere_first
    types = types_of({ "handed" => "parts = [:en]\nparts.each_slice(1) { |slice| slice << :x }\nresult = [locale]\nresult += parts\nresult" })

    refute_match(/\A\[/, types.fetch("handed"))
  end

  def test_a_loop_inside_a_loop_pushes_once_per_pass_of_each
    types = types_of({
      "inner_only" => "result = []\n[locale, :en].each do |tag|\n  [tag, :x].each { |inner| result << inner }\nend\nresult",
      "both" => "result = []\n[locale].each do |tag|\n  result << tag\n  [:x, :y].each { |inner| result += [inner] }\nend\nresult",
      "inner_reads_outer_local" => "result = []\n[locale, :en].each do |tag|\n  parts = [tag]\n  parts.each { |inner| result << inner }\nend\nresult"
    })

    assert_equal "[:fr, :x, :en, :x]", types.fetch("inner_only")
    assert_equal "[:fr, :x, :y]", types.fetch("both")
    assert_equal "[:fr, :en]", types.fetch("inner_reads_outer_local")
  end

  def test_declines_a_loop_inside_a_loop_it_cannot_count_or_that_names_the_local
    types = types_of({
      "unknown" => "result = []\n[locale].each do |tag|\n  tag.to_s.chars.each { |char| result << char }\nend\nresult",
      "named" => "result = []\n[locale].each do |tag|\n  [:x].each { |inner| other = result\n other << inner }\nend\nresult"
    })

    refute_match(/\A\[/, types.fetch("unknown"))
    refute_match(/\A\[/, types.fetch("named"))
  end

  def test_asking_an_element_what_it_is_leaves_the_local_readable
    types = types_of({
      "query" => "parts = [locale]\nparts.last.is_a?(Symbol)\nparts.join(\",\")",
      "changed" => "parts = [\"a\"]\nparts.last << \"b\"\nparts.join(\",\")"
    })

    assert_equal '"fr"', types.fetch("query")
    assert_equal "::String", types.fetch("changed")
  end

  def test_an_arm_a_computed_value_decides_is_counted
    types = types_of({
      "literal" => "result = [locale]\nresult << :x if [locale].include?(:fr)\nresult",
      "compared" => "seen = false\nresult = [locale]\nresult << :x if seen == false\nresult",
      "else" => "result = [locale]\nresult << :x if nil\nresult"
    })

    assert_equal "[:fr, :x]", types.fetch("literal")
    assert_equal "[:fr, :x]", types.fetch("compared")
    assert_equal "[:fr]", types.fetch("else")
  end

  def test_declines_an_arm_only_a_declaration_takes
    in_tmpdir do
      write("sig/p.rbs", "class P\n  @h: Hash[Symbol, Array[Symbol]]\n  def go: (:fr locale) -> untyped\n  def read: (:fr locale) -> untyped\n  def unset: (:fr locale) -> untyped\nend\n")
      write("app/p.rb", <<~RUBY)
        class P
          def go(locale)
            result = []
            [locale].each { |tag| result += [:x] if @h[tag] }
            result
          end

          def read(locale)
            result = [locale]
            result += [:x] if @h[locale]
            result
          end

          def unset(locale)
            result = []
            result << :x if @h
            result
          end
        end
      RUBY
      types = body_types(setup_project, current_dir + "app/p.rb")

      %w[go read unset].each { |name| refute_match(/\A\[/, types.fetch(name), name) }
    end
  end

  def test_asking_whether_a_local_is_empty_reads_what_it_holds
    types = types_of({
      "empty" => "parts = []\nparts.empty?",
      "held" => "parts = []\nparts << locale\nparts.empty?",
      "decided" => "result = []\nparts = []\nresult << :none if parts.empty?\nresult << :some unless parts.empty?\nresult"
    })

    assert_equal "true", types.fetch("empty")
    assert_equal "false", types.fetch("held")
    assert_equal "[:none]", types.fetch("decided")
  end

  def test_flat_map_over_a_known_collection_splices_what_each_pass_hands_back
    types = types_of({
      "arrays" => "[locale, :en].flat_map { |tag| [tag, :x] }",
      "values" => "[locale, :en].flat_map { |tag| tag }",
      "empty" => "[].flat_map { |tag| [tag] }",
      "unknown" => "[locale].flat_map { |tag| tag.to_s.chars }"
    })

    assert_equal "[:fr, :x, :en, :x]", types.fetch("arrays")
    assert_equal "[:fr, :en]", types.fetch("values")
    assert_equal "[]", types.fetch("empty")
    refute_match(/\A\[/, types.fetch("unknown"))
  end

  def test_a_change_under_an_if_takes_the_local_away_only_where_its_arm_may_run
    types = types_of({
      "dead" => "parts = [:a]\nparts.pop if parts.empty?\nparts",
      "live" => "parts = [:a]\nparts.pop unless parts.empty?\nparts",
      "open" => "parts = [:a]\nparts.pop if rand > 0.5\nparts"
    })

    assert_equal "[:a]", types.fetch("dead")
    refute_match(/\A\[/, types.fetch("live"))
    refute_match(/\A\[/, types.fetch("open"))
  end

  def test_flat_map_reads_what_a_local_holds
    types = types_of({ "flat_map" => "parts = [locale]\nparts.flat_map { |tag| [tag, :en] }" })

    assert_equal "[:fr, :en]", types.fetch("flat_map")
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

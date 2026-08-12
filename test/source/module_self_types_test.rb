require_relative "../test_helper"
require "tmpdir"

class Steep::Source::ModuleSelfTypesTest < Minitest::Test
  M = Steep::Source::ModuleSelfTypes

  CONCERN = ["# @type self: singleton(Post) & singleton(Post::Notifiable)",
             "# @type instance: Post & Post::Notifiable"].freeze

  # --- inject: placement (the genuinely-Steep behavior) ---

  def test_inject_appends_at_end_for_top_level_module
    source = <<~RUBY
      module Post::Notifiable
        extend ActiveSupport::Concern

        included do
        end
      end
    RUBY

    result = M.inject(source, annotations: CONCERN, anchor: "Notifiable")
    lines = result.lines

    module_close_idx = lines.rindex { |l| l.strip == "end" }
    self_idx         = lines.index { |l| l.include?("@type self:") }
    instance_idx     = lines.index { |l| l.include?("@type instance:") }

    assert self_idx > module_close_idx
    assert instance_idx > module_close_idx
    assert_includes result, CONCERN[0]
    assert_includes result, CONCERN[1]
  end

  def test_inject_preserves_original_line_numbers
    source = <<~RUBY
      module Post::Notifiable
        extend ActiveSupport::Concern

        def notify
          "hello"
        end
      end
    RUBY

    result = M.inject(source, annotations: CONCERN, anchor: "Notifiable")

    source.lines.each_with_index do |line, i|
      assert_equal line, result.lines[i], "Line #{i + 1} shifted after annotation"
    end
  end

  def test_inject_into_nested_module_goes_inside_body
    source = <<~RUBY
      module Search
        class Record
          module SQLite
            extend ActiveSupport::Concern
          end
        end
      end
    RUBY
    annotations = ["# @type self: singleton(Search::Record) & singleton(Search::Record::SQLite)",
                   "# @type instance: Search::Record & Search::Record::SQLite"]

    result = M.inject(source, annotations: annotations, anchor: "SQLite")
    lines = result.lines

    sqlite_open = lines.index { |l| l.include?("module SQLite") }
    annotation  = lines.index { |l| l.include?("@type self:") }
    closing_ends = lines.each_index.select { |i| lines[i].strip == "end" }

    assert annotation > sqlite_open
    assert annotation < closing_ends.last, "annotation must be inside the body, not after the closing ends"
  end

  def test_inject_is_idempotent
    source = <<~RUBY
      module Post::Notifiable
        extend ActiveSupport::Concern

        # @type self: singleton(Post) & singleton(Post::Notifiable)
        # @type instance: Post & Post::Notifiable

        included do
        end
      end
    RUBY

    assert_equal source, M.inject(source, annotations: CONCERN, anchor: "Notifiable")
  end

  def test_inject_single_instance_annotation
    source = <<~RUBY
      module Post::Taggable
        def tag_names
        end
      end
    RUBY
    annotations = ["# @type instance: Post & Post::Taggable"]

    result = M.inject(source, annotations: annotations, anchor: "Taggable")

    assert_includes result, "# @type instance: Post & Post::Taggable"
    refute_includes result, "@type self:"
  end

  def test_inject_falls_back_to_append_on_unparseable_source
    source = "module Broken\n  def x(\n"
    annotations = ["# @type instance: Foo & Broken"]

    result = M.inject(source, annotations: annotations, anchor: "Broken")

    assert_includes result, "# @type instance: Foo & Broken"
  end

  # --- inject_blocks: @implements into a DSL block body ---

  TAGGABLE = <<~RUBY
    module Post
      module Taggable
        class_methods do
          def default_tag_names
            ["news"]
          end
        end
      end
    end
  RUBY

  BLOCKS = [{ "call" => "class_methods", "implements" => "::Post::Taggable::ClassMethods" }].freeze

  BLOCKS_WITH_SELF = [{
    "call" => "class_methods",
    "implements" => "::Post::Taggable::ClassMethods",
    "self" => "singleton(::Post) & singleton(::Post::Taggable)"
  }].freeze

  def test_inject_blocks_appends_self_on_each_def_line_without_shifting
    source = <<~RUBY
      module Post
        module Taggable
          class_methods do
            def default_tag_names
              ["news"]
            end

            def known_tag?(name)
              default_tag_names.include?(name)
            end
          end
        end
      end
    RUBY

    result = M.inject_blocks(source, blocks: BLOCKS_WITH_SELF)
    lines = result.lines

    # No line added.
    assert_equal source.lines.size, lines.size

    # @implements on the opener, @type self on each def line, every other line intact.
    self_ann = "# @type self: singleton(::Post) & singleton(::Post::Taggable)"
    source.lines.each_with_index do |orig, i|
      case
      when orig.include?("class_methods do")
        assert_includes lines[i], "@implements ::Post::Taggable::ClassMethods"
        assert lines[i].start_with?(orig.chomp)
      when orig.include?("def default_tag_names"), orig.include?("def known_tag?")
        assert_includes lines[i], self_ann, "def line #{i + 1} must carry @type self"
        assert lines[i].start_with?(orig.chomp)
      else
        assert_equal orig, lines[i], "line #{i + 1} must not move or change"
      end
    end

    assert_equal 2, lines.count { |l| l.include?(self_ann) }
  end

  def test_inject_blocks_with_self_is_idempotent
    once  = M.inject_blocks(TAGGABLE, blocks: BLOCKS_WITH_SELF)
    twice = M.inject_blocks(once, blocks: BLOCKS_WITH_SELF)
    assert_equal once, twice
    assert_equal 1, twice.lines.count { |l| l.include?("@type self:") }
    assert_equal 1, twice.lines.count { |l| l.include?("@implements") }
  end

  def test_inject_blocks_without_self_adds_no_type_self
    result = M.inject_blocks(TAGGABLE, blocks: BLOCKS)
    refute_includes result, "@type self:"
  end

  def test_inject_blocks_appends_implements_on_the_opener_line
    result = M.inject_blocks(TAGGABLE, blocks: BLOCKS)
    lines = result.lines

    do_line = lines.find { |l| l.include?("class_methods do") }
    assert_includes do_line, "@implements ::Post::Taggable::ClassMethods",
                    "annotation must ride on the `do` line itself"
    assert_match(/class_methods do # @implements ::Post::Taggable::ClassMethods/, do_line)
  end

  def test_inject_blocks_adds_no_line_and_keeps_every_other_line
    result = M.inject_blocks(TAGGABLE, blocks: BLOCKS)
    lines = result.lines
    original = TAGGABLE.lines

    # No line added → line numbers Steep reports stay aligned with the source.
    assert_equal original.size, lines.size

    original.each_with_index do |orig, i|
      if orig.include?("class_methods do")
        # The opener line only gains a trailing comment.
        assert lines[i].start_with?(orig.chomp), "opener line #{i + 1} must keep its prefix"
        assert_includes lines[i], "@implements"
      else
        assert_equal orig, lines[i], "line #{i + 1} must not move or change"
      end
    end
  end

  def test_inject_blocks_skips_inline_block_rather_than_corrupting_it
    # An inline `{ … }` body shares the opener line; appending a `#` comment
    # there would swallow the body, so the block is left untouched.
    source = "module M\n  class_methods { def x; end }\nend\n"
    assert_equal source, M.inject_blocks(source, blocks: BLOCKS)
  end

  def test_inject_blocks_preserves_lines_before_the_block
    result = M.inject_blocks(TAGGABLE, blocks: BLOCKS)

    # Everything up to and including `class_methods do` is byte-for-byte intact
    # (we insert *after* the `do`).
    prefix = TAGGABLE[0..TAGGABLE.index("class_methods do") + "class_methods do".length - 1]
    assert result.start_with?(prefix)
  end

  def test_inject_blocks_is_idempotent
    once  = M.inject_blocks(TAGGABLE, blocks: BLOCKS)
    twice = M.inject_blocks(once, blocks: BLOCKS)
    assert_equal once, twice
    assert_equal 1, twice.lines.count { |l| l.include?("@implements ::Post::Taggable::ClassMethods") }
  end

  def test_inject_blocks_ignores_unmatched_call_name
    result = M.inject_blocks(TAGGABLE, blocks: [{ "call" => "included", "implements" => "X" }])
    assert_equal TAGGABLE, result
  end

  def test_inject_blocks_skips_call_with_receiver
    source = <<~RUBY
      module Post
        module Taggable
          helper.class_methods do
            def x; end
          end
        end
      end
    RUBY

    assert_equal source, M.inject_blocks(source, blocks: BLOCKS)
  end

  def test_inject_blocks_noop_for_empty_blocks
    assert_equal TAGGABLE, M.inject_blocks(TAGGABLE, blocks: [])
  end

  def test_inject_blocks_falls_back_on_unparseable_source
    source = "module Broken\n  class_methods do\n"
    assert_equal source, M.inject_blocks(source, blocks: BLOCKS)
  end

  # --- entry_for: sidecar loading ---

  def test_entry_for_reads_sidecar_keyed_by_path
    with_sidecar(
      "app/models/search/record/sqlite.rb" => {
        "anchor" => "SQLite",
        "annotations" => ["# @type instance: Search::Record & Search::Record::SQLite"]
      }
    ) do
      entry = M.entry_for("app/models/search/record/sqlite.rb")
      assert_equal "SQLite", entry["anchor"]
      assert_includes entry["annotations"].first, "Search::Record::SQLite"
    end
  end

  def test_entry_for_matches_absolute_path_by_tail
    with_sidecar("app/models/post/taggable.rb" => { "anchor" => "Taggable", "annotations" => [] }) do |dir|
      entry = M.entry_for("#{dir}/app/models/post/taggable.rb")
      assert_equal "Taggable", entry["anchor"]
    end
  end

  # Prism counts offsets in BYTES. Slicing the String by that number is a
  # CHARACTER index, so one multi-byte character above the anchor slid the
  # insertion past the module's own `end` and into its parent's body — where
  # the annotation binds to the wrong scope and quietly does nothing.
  def test_inject_places_the_annotation_inside_the_module_with_multibyte_text_above
    source = <<~RUBY
      # A comment with an em dash — and another —
      module Outer
        module Inner
          def x
          end
        end
      end
    RUBY

    result = M.inject(source, annotations: ["# @type instance: A & B"], anchor: "Inner")
    lines = result.lines

    annotation = lines.index { |l| l.include?("@type instance") }
    inner_end = lines.index { |l| l.rstrip == "  end" }

    assert annotation < inner_end,
           "annotation must sit inside Inner's body, before its `end`:\n#{result}"
  end

  # --- self_types_of: one file can declare several modules ---

  def test_self_types_of_reads_every_module_of_an_entry
    entry = {
      "modules" => [
        { "anchor" => "ControllerMethods", "annotations" => ["# @type instance: A & B"] },
        { "anchor" => "Token", "annotations" => ["# @type instance: C & D"] }
      ]
    }

    assert_equal %w[ControllerMethods Token], M.self_types_of(entry).map { |m| m["anchor"] }
  end

  # A sidecar written before `modules` existed still applies.
  def test_self_types_of_reads_a_top_level_anchor_as_one_module
    entry = { "anchor" => "SQLite", "annotations" => ["# @type instance: A & B"] }

    assert_equal [entry], M.self_types_of(entry)
  end

  def test_self_types_of_is_empty_for_a_blocks_only_entry
    assert_empty M.self_types_of({ "blocks" => [{ "call" => "class_methods" }] })
  end

  def test_entry_for_nil_without_sidecar
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        M.reset!
        assert_nil M.entry_for("app/models/post/taggable.rb")
      end
    end
  ensure
    M.reset!
  end

  def test_entry_for_reloads_after_sidecar_mtime_changes
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        M.reset!
        dump_sidecar({ "a.rb" => { "anchor" => "A", "annotations" => [] } }, mtime: Time.at(1_000_000))
        assert M.entry_for("a.rb")
        assert_nil M.entry_for("b.rb")

        dump_sidecar(
          { "a.rb" => { "anchor" => "A", "annotations" => [] },
            "b.rb" => { "anchor" => "B", "annotations" => [] } },
          mtime: Time.at(2_000_000)
        )
        assert M.entry_for("b.rb"), "regenerated sidecar must be picked up"
      end
    end
  ensure
    M.reset!
  end

  NARROWED = <<~RUBY
    class Example23
      module Foo
        def bazinga(module_included)
          module_included.bazingado(self)
        end

        def bazingado(base_foo)
          base_foo
        end
      end
    end
  RUBY

  def test_inject_defs_annotates_only_the_named_method
    result = M.inject_defs(NARROWED, defs: { "bazinga" => "singleton(::Example23::Bar)" }, anchor: "Foo")
    lines = result.lines

    # Rides the signature line, so nothing shifts.
    assert_equal NARROWED.lines.size, lines.size

    NARROWED.lines.each_with_index do |orig, i|
      if orig.include?("def bazinga(")
        assert_includes lines[i], "# @type self: singleton(::Example23::Bar)"
        assert lines[i].start_with?(orig.chomp)
      else
        assert_equal orig, lines[i]
      end
    end
  end

  def test_inject_defs_is_idempotent
    once  = M.inject_defs(NARROWED, defs: { "bazinga" => "singleton(::Example23::Bar)" }, anchor: "Foo")
    twice = M.inject_defs(once, defs: { "bazinga" => "singleton(::Example23::Bar)" }, anchor: "Foo")
    assert_equal once, twice
    assert_equal 1, twice.lines.count { |l| l.include?("@type self:") }
  end

  # The sidecar is the only untrusted input here, so a wrong shape is checked
  # for by name instead of caught by a blanket rescue — and it is logged, not
  # swallowed.
  def test_inject_defs_leaves_the_source_alone_for_a_malformed_sidecar
    assert_equal NARROWED, M.inject_defs(NARROWED, defs: ["bazinga"], anchor: "Foo")
    assert_equal NARROWED, M.inject_defs(NARROWED, defs: { "bazinga" => 42 }, anchor: "Foo")
    assert_equal NARROWED, M.inject_defs(NARROWED, defs: { "bazinga" => "  " }, anchor: "Foo")
  end

  # A bug in this file has to surface, which a blanket rescue would have turned
  # into "the annotation silently stopped being placed".
  def test_inject_defs_does_not_swallow_an_unexpected_error
    M.stub(:find_target_scope, ->(*) { raise "boom" }) do
      assert_raises(RuntimeError) do
        M.inject_defs(NARROWED, defs: { "bazinga" => "singleton(::Example23::Bar)" }, anchor: "Foo")
      end
    end
  end

  def test_inject_defs_ignores_an_unknown_anchor_or_method
    assert_equal NARROWED, M.inject_defs(NARROWED, defs: { "bazinga" => "singleton(::X)" }, anchor: "Nope")
    assert_equal NARROWED, M.inject_defs(NARROWED, defs: { "nope" => "singleton(::X)" }, anchor: "Foo")
    assert_equal NARROWED, M.inject_defs(NARROWED, defs: {}, anchor: "Foo")
    assert_equal NARROWED, M.inject_defs(NARROWED, defs: nil, anchor: "Foo")
  end

  # A `def self.x`'s self is the module object, which no invoker narrows and
  # which the module-wide annotation already covers.
  def test_inject_defs_leaves_a_singleton_method_alone
    source = <<~RUBY
      class Example23
        module Foo
          def self.bazinga(x)
            x
          end
        end
      end
    RUBY

    assert_equal source, M.inject_defs(source, defs: { "bazinga" => "singleton(::Example23::Bar)" }, anchor: "Foo")
  end

  # A def whose body shares the signature line has nowhere to put the comment
  # without swallowing the body, so it is skipped rather than shifted.
  def test_inject_defs_skips_a_def_with_an_inline_body
    source = <<~RUBY
      class Example23
        module Foo
          def bazinga(x) = x
        end
      end
    RUBY

    assert_equal source, M.inject_defs(source, defs: { "bazinga" => "singleton(::Example23::Bar)" }, anchor: "Foo")
  end

  private

  def with_sidecar(table)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        M.reset!
        dump_sidecar(table)
        yield dir
      end
    end
  ensure
    M.reset!
  end

  def dump_sidecar(table, mtime: nil)
    path = Steep::Source::ModuleSelfTypes::DEFAULT_SIDECAR_PATH
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, YAML.dump(table))
    File.utime(File.atime(path), mtime, path) if mtime
    M.reset!
  end
end

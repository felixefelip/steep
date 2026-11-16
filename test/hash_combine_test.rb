require_relative "test_helper"
require_relative "specializations_project_helper"

class HashCombineTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def probe(lines)
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        class Reflection
        end
        class Probe
          def probe: () -> untyped
          def combine: (Hash[Symbol, untyped] held, Symbol name, Reflection value) -> untyped
        end
      RBS
      write("app/app.rb", <<~RUBY)
        class Reflection
        end
        class Probe
          def probe
            #{lines}
          end

          def combine(held, name, value) = held.except(name).merge!(name => value)
        end
        Probe.new.combine({ posts: Reflection.new }, :comments, Reflection.new)
      RUBY
      project = setup_project
      [body_types(project, current_dir + "app/app.rb").fetch("probe"), Steep::Specializations::Runner.new(project).run.fetch("Probe#combine", {}).values]
    end
  end

  def test_except_drops_a_literal_key
    assert_equal "{ :b => 2 }", probe("h = {}\nh[:a] = 1\nh[:b] = 2\nh.except(:a)").first
  end

  def test_merge_adds_the_entries_written_at_the_call
    assert_equal "{ :a => 1, :b => ::Reflection }", probe("h = {}\nh[:a] = 1\nh.merge(b: Reflection.new)").first
  end

  def test_merge_bang_on_a_hash_except_just_built_adds_them
    assert_equal "{ :b => 2 }", probe("h = {}\nh[:a] = 1\nh.except(:a).merge!(b: 2)").first
  end

  def test_merge_bang_on_a_local_leaves_what_it_holds_unknown
    assert_equal "bool", probe("h = {}\nh.merge!(b: 2)\nh.key?(:b)").first
  end

  def test_a_key_a_parameter_carries_is_a_literal_key
    assert_equal ["{ :comments => ::Reflection, :posts => ::Reflection }"], probe("1").last
  end
end

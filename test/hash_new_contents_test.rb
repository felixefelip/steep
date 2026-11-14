require_relative "test_helper"
require_relative "specializations_project_helper"

class HashNewContentsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def body_types_of(body)
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        class Probe
          def fill: (Hash[Symbol, Integer] hash) -> void
          def probe: () -> untyped
        end
      RBS
      write("app/app.rb", <<~RUBY)
        class Probe
          def fill(hash) = hash[:a] = 1

          #{body}
        end
      RUBY
      body_types(setup_project, current_dir + "app/app.rb")
    end
  end

  def probe(lines) = body_types_of("def probe\n#{lines}\nend").fetch("probe")

  def test_a_hash_built_with_a_default_block_holds_no_key
    assert_equal "false", probe("h = Hash.new { |_hash, key| key }\nh.key?(:missing)")
  end

  def test_a_key_written_to_a_hash_built_with_a_default_is_held
    assert_equal "true", probe("h = Hash.new(0)\nh[:a] = 1\nh.key?(:a)")
    assert_equal "1", probe("h = Hash.new(0)\nh[:a] = 1\nh[:a]")
  end

  def test_a_key_the_hash_does_not_hold_is_left_to_the_default
    assert_equal "::Integer", probe("h = Hash.new(0)\nh[:a] = 1\nh[:b]")
  end

  def test_a_hash_another_name_reaches_holds_what_it_may
    assert_equal "bool", probe("h = Hash.new(0)\ng = h\ng[:a] = 1\nh.key?(:a)")
    assert_equal "bool", probe("h = Hash.new(0)\nfill(h)\nh.key?(:a)")
    assert_equal "bool", probe("h = Hash.new(0)\n[1].each { h[:a] = 1 }\nh.key?(:a)")
  end
end

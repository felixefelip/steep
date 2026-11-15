require_relative "test_helper"
require_relative "specializations_project_helper"

class DefaultBlockKeyTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def diagnostics_of(body)
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        class Labels
          def label_for: (:missing key) -> untyped
          def keep: (untyped hash) -> untyped
        end
      RBS
      write("app/app.rb", <<~RUBY)
        class Labels
          def keep(hash) = hash

          #{body}
        end
      RUBY
      project = setup_project
      checked(project, current_dir + "app/app.rb").errors.map { |error| error.class.name.split("::").last }
    end
  end

  def test_the_key_a_default_block_receives_is_the_key_its_reads_pass
    assert_empty diagnostics_of(<<~RUBY)
      def label_for(key)
        labels = Hash.new { |_labels, missing| missing.to_s }
        labels[key]
      end
    RUBY
  end

  def test_a_literal_key_is_the_key_too
    assert_empty diagnostics_of(<<~RUBY)
      def label_for(key)
        labels = Hash.new { |_labels, missing| missing.to_s }
        labels[:other]
      end
    RUBY
  end

  def test_a_hash_another_name_reaches_keeps_the_declared_key
    assert_includes diagnostics_of(<<~RUBY), "NoMethod"
      def label_for(key)
        labels = Hash.new { |_labels, missing| missing.to_s }
        keep(labels)
        labels[key]
      end
    RUBY
  end

  def test_a_key_the_block_cannot_know_where_it_is_written_keeps_the_declared_key
    assert_includes diagnostics_of(<<~RUBY), "NoMethod"
      def label_for(key)
        labels = Hash.new { |_labels, missing| missing.to_s }
        other = key
        labels[other]
      end
    RUBY
  end

  def test_a_block_whose_type_declares_no_parameters_is_left_alone
    assert_empty diagnostics_of("def label_for(key) = proc { key }")
  end
end

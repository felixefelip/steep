require_relative "test_helper"
require_relative "specializations_project_helper"

class ClassStateAfterLoadTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RUBY = <<~'RUBY'
    class Catalog
      @lookups = {}

      def self.lookup(entry)
        found = @lookups[entry]
        return found if found

        value = "Catalog::#{entry}"
        @lookups[entry] = value
        value
      end

      def self.reset(entry)
        @lookups[entry] = :reset
      end
    %{catalog}
    end

    class Admin
      def self.clear = Catalog.reset("Item")
    end

    class Reader
      def self.label = Catalog.lookup("Item")
    end

    class App
      def self.run
    %{run}
      end
    end
  RUBY

  RBS = <<~RBS
    class Catalog
      self.@lookups: Hash[untyped, untyped]
      def self.lookup: ("Item" entry) -> untyped
      def self.reset: ("Item" entry) -> :reset
    end
    class Admin
      def self.clear: () -> :reset
    end
    class Reader
      def self.label: () -> untyped
    end
    class App
      def self.run: () -> untyped
    end
  RBS

  def declarations(run, catalog: "")
    in_tmpdir do
      write("sig/app.rbs", RBS.sub("    def self.reset", "    def self.warm: () -> untyped\n    def self.reset"))
      write("app/app.rb", format(RUBY, run: run, catalog: catalog))
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.declarations.slice("Catalog.lookup", "Reader.label")
    end
  end

  def test_a_method_nothing_calls_reads_the_class_as_the_load_left_it
    assert_equal({ "Catalog.lookup" => '"Catalog::Item"', "Reader.label" => '"Catalog::Item"' }, declarations("    Reader.label"))
  end

  def test_a_class_method_nothing_calls_reads_its_own_ivars_as_the_load_left_them
    assert_equal({ "Catalog.lookup" => '"Catalog::Item"' }, declarations("    nil", catalog: "  def self.warm = lookup(\"Item\")"))
  end

  def test_a_call_leaves_the_class_holding_what_its_body_stored_under_a_string_key
    assert_equal({ "Catalog.lookup" => ":reset", "Reader.label" => ":reset" }, declarations("    Admin.clear\n    Reader.label"))
  end

  def test_a_store_made_after_the_read_is_not_what_the_read_finds
    assert_equal({ "Catalog.lookup" => '"Catalog::Item"', "Reader.label" => '"Catalog::Item"' }, declarations("    label = Reader.label\n    Admin.clear\n    label"))
  end

  def test_each_read_finds_what_the_class_holds_at_that_point
    assert_equal({ "Catalog.lookup" => '("Catalog::Item" | :reset)', "Reader.label" => '("Catalog::Item" | :reset)' }, declarations("    before = Reader.label\n    Admin.clear\n    [before, Reader.label]"))
  end
end

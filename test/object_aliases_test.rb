require_relative "test_helper"
require_relative "specializations_project_helper"

class ObjectAliasesTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RUBY = <<~'RUBY'
    class Catalog
      def initialize
        @lookups = {}
      end

      def lookup(entry)
        found = @lookups[entry]
        return found if found

        value = "Catalog::#{entry}"
        @lookups[entry] = value
        value
      end

      def reset(entry)
        @lookups[entry] = :reset
      end
    end

    class Admin
      def initialize(catalog)
        @catalog = catalog
      end

      def clear = @catalog.reset("Item")
    end

    class Wiper
      def self.wipe(catalog) = catalog.reset("Item")
    end

    class Reader
      def initialize(catalog)
        @catalog = catalog
      end

      def label = @catalog.lookup("Item")
    end

    class App
      def self.run
    %{run}
      end
    end
  RUBY

  RBS = <<~RBS
    class Catalog
      @lookups: Hash[untyped, untyped]
      def initialize: () -> void
      def lookup: (untyped entry) -> untyped
      def reset: (untyped entry) -> :reset
    end
    class Admin
      @catalog: Catalog
      def initialize: (Catalog catalog) -> void
      def clear: () -> :reset
    end
    class Wiper
      def self.wipe: (Catalog catalog) -> :reset
    end
    class Reader
      @catalog: Catalog
      def initialize: (Catalog catalog) -> void
      def label: () -> untyped
    end
    class App
      def self.run: () -> untyped
    end
  RBS

  def label(run)
    in_project(run) do
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.declarations["Reader#label"]
    end
  end

  def type_at(run, source)
    in_project(run) do
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.write(runner.run)
      typing = checked(setup_project, current_dir + "app/app.rb")
      node, = typing.each_typing.select { |node, _| node.loc.expression&.source == source }.last
      typing.type_of(node: node).to_s
    end
  end

  def in_project(run)
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", format(RUBY, run: run.gsub(/^/, "    ")))
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      yield
    end
  end

  def test_a_write_through_an_ivar_bound_from_a_local_reaches_the_local
    assert_equal ":reset", label(<<~RUBY)
      catalog = Catalog.new
      Admin.new(catalog).clear
      Reader.new(catalog).label
    RUBY
  end

  def test_a_read_made_before_the_write_finds_what_was_there
    assert_equal '"Catalog::Item"', label(<<~RUBY)
      catalog = Catalog.new
      label = Reader.new(catalog).label
      Admin.new(catalog).clear
      label
    RUBY
  end

  def test_a_write_through_one_object_reaches_an_ivar_another_object_holds
    assert_equal '("Catalog::Item" | :reset)', label(<<~RUBY)
      catalog = Catalog.new
      reader = Reader.new(catalog)
      before = reader.label
      Admin.new(catalog).clear
      after = reader.label
      [before, after]
    RUBY
  end

  def test_two_objects_built_alike_are_two_objects
    assert_equal '"Catalog::Item"', label(<<~RUBY)
      cleared = Catalog.new
      read = Catalog.new
      Admin.new(cleared).clear
      Reader.new(read).label
    RUBY
  end

  def test_an_object_kept_where_no_name_follows_it_is_settled
    assert_nil label(<<~RUBY)
      catalog = Catalog.new
      admins = [Admin.new(catalog)]
      admins.each(&:clear)
      Reader.new(catalog).label
    RUBY
  end

  def test_a_write_through_each_element_of_an_array_reaches_the_local
    assert_equal ":reset", label(<<~RUBY)
      catalog = Catalog.new
      admins = []
      admins << Admin.new(catalog)
      admins.each(&:clear)
      Reader.new(catalog).label
    RUBY
  end

  def test_a_write_in_a_block_over_an_array_reaches_the_local
    assert_equal ":reset", label(<<~RUBY)
      catalog = Catalog.new
      admins = []
      admins << Admin.new(catalog)
      admins.each { |admin| admin.clear }
      Reader.new(catalog).label
    RUBY
  end

  def test_an_element_holds_what_a_write_after_the_push_left
    assert_equal '[::Admin{@catalog: ::Catalog{@lookups: { "Item" => :reset }}}]', type_at(<<~RUBY, "admins")
      catalog = Catalog.new
      admins = []
      admins << Admin.new(catalog)
      Admin.new(catalog).clear
      admins
    RUBY
  end

  def test_an_element_handed_on_after_the_push_is_settled
    assert_equal "[::Admin{@catalog: ::Catalog}]", type_at(<<~RUBY, "admins.each(&:clear)")
      catalog = Catalog.new
      admins = []
      admins << Admin.new(catalog)
      Wiper.wipe(catalog)
      admins.each(&:clear)
      nil
    RUBY
  end
end

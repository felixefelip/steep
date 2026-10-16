require_relative "test_helper"

class HashMemoStateTest < Minitest::Test
  include TestHelper
  include ShellHelper

  def dirs = (@dirs ||= [])

  def write(relative, content)
    path = current_dir + relative
    path.parent.mkpath
    path.write(content)
  end

  def setup_project
    steepfile = "target :app do\n  signature \"sig\"\n  check \"app\"\nend\n"
    write("Steepfile", steepfile)
    project = Steep::Project.new(steepfile_path: current_dir + "Steepfile")
    Steep::Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
    project
  end

  def chunks(ruby, rbs: RBS)
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      return runner.evals.transform_values { |chunks| chunks.map { |chunk| chunk&.source } }
    end
  end

  RBS = <<~RBS
    class Base
      self.@registry: Hash[Symbol, Symbol]?
      def self.registry: () -> Hash[Symbol, Symbol]
      def self.register: (Symbol name, Symbol value) -> Symbol
      def self.lookup: (Symbol name) -> Symbol
      def self.define_named: (Symbol name) -> untyped
    end
    class Car < Base
    end
    class Truck < Base
    end
  RBS

  RUBY = <<~'RUBY'
    class Base
      def self.registry
        @registry ||= {}
      end

      def self.register(name, value)
        registry[name] = value
      end

      def self.lookup(name)
        registry[name]
      end

      def self.define_named(name)
        class_eval("def #{lookup(name)}; end")
      end
    end

    class Car < Base
      register :wheel, :round
      register :seat, :soft
      define_named :wheel
      define_named :seat
    end

    class Truck < Base
      register :seat, :bench
      define_named :seat
    end
  RUBY

  def test_a_read_by_literal_key_answers_what_this_class_stored
    assert_equal(
      { "app/app.rb:22:2" => ["def round; end"], "app/app.rb:23:2" => ["def soft; end"], "app/app.rb:28:2" => ["def bench; end"] },
      chunks(RUBY)
    )
  end

  def test_declines_a_hash_something_else_may_change
    {
      "the memo's hash handed out" => ["  def self.all = registry\n", "RBS_ALL"],
      "a call the hash is not followed through" => ["  def self.reset = registry.clear\n", "RBS_RESET"]
    }.each do |change, (method, _)|
      ruby = RUBY.sub("  def self.lookup(name)", "#{method}\n  def self.lookup(name)")
      ruby = ruby.sub("  register :seat, :soft\n", "  register :seat, :soft\n  reset\n") if change.include?("followed")
      rbs = RBS.sub("    def self.lookup:", "    def self.all: () -> untyped\n    def self.reset: () -> untyped\n    def self.lookup:")

      assert_equal [nil], chunks(ruby, rbs: rbs)["app/app.rb:#{change.include?("followed") ? 26 : 25}:2"], change
    end
  end

  def test_a_store_under_a_key_that_is_no_literal_leaves_the_hash_unknown
    ruby = RUBY.sub("  register :seat, :soft\n", "  register :seat, :soft\n  register Time.now.to_s.to_sym, :odd\n")

    assert_equal [nil], chunks(ruby)["app/app.rb:23:2"]
  end

  def test_a_string_eval_that_runs_code_leaves_the_hash_unknown
    ruby = RUBY.sub('class_eval("def #{lookup(name)}; end")', 'class_eval("def #{lookup(name)}; end; register :wheel, :flat")')

    assert_equal({ "app/app.rb:22:2" => ["def round; end; register :wheel, :flat"], "app/app.rb:23:2" => [nil] },
                 chunks(ruby).slice("app/app.rb:22:2", "app/app.rb:23:2"))
  end

  def test_an_object_stored_under_a_key_is_read_back_as_its_class
    rbs = RBS.sub("class Car < Base", "class Wheel\n  def name: () -> :wheel_part\nend\nclass Car < Base")
             .gsub("Symbol value", "untyped value").sub("def self.lookup: (Symbol name) -> Symbol", "def self.lookup: (Symbol name) -> untyped")
             .sub("self.@registry: Hash[Symbol, Symbol]?", "self.@registry: Hash[Symbol, untyped]?").sub("def self.registry: () -> Hash[Symbol, Symbol]", "def self.registry: () -> Hash[Symbol, untyped]")
    ruby = RUBY.sub("class Car < Base", "class Wheel\n  def name = :wheel_part\nend\n\nclass Car < Base")
               .sub("register :wheel, :round", "register :wheel, Wheel.new")
               .sub('class_eval("def #{lookup(name)}; end")', 'class_eval("def #{lookup(name).name}; end")')

    assert_equal ["def wheel_part; end"], chunks(ruby, rbs: rbs)["app/app.rb:26:2"]
  end

  def test_an_object_whose_construction_may_reach_the_class_leaves_the_hash_unknown
    rbs = RBS.sub("class Car < Base", "class Spoiler\n  def initialize: () -> void\nend\nclass Car < Base").gsub("Symbol value", "untyped value")
    ruby = RUBY.sub("class Car < Base", "class Spoiler\n  def initialize\n    Car.register(:wheel, :flat)\n  end\nend\n\nclass Car < Base")
               .sub("register :seat, :soft", "register :seat, Spoiler.new")

    assert_equal [nil], chunks(ruby, rbs: rbs)["app/app.rb:28:2"]
  end

  def test_a_read_under_a_key_the_hash_does_not_hold_answers_no_other_value
    ruby = RUBY.sub("  register :seat, :bench\n  define_named :seat\n", "  register :seat, :bench\n  define_named :seat\n  define_named :wheel\n")

    assert_equal [nil], chunks(ruby)["app/app.rb:29:2"]
  end

  def test_an_object_built_with_a_block_may_reach_the_class
    rbs = RBS.sub("class Car < Base", "class Maker\n  def initialize: () { () -> void } -> void\nend\nclass Car < Base")
    ruby = RUBY.sub("class Car < Base", "class Maker\n  def initialize = yield\nend\n\nclass Car < Base")
               .sub("  register :seat, :soft\n", "  register :seat, :soft\n  Maker.new { register :wheel, :flat }\n")

    assert_equal [nil], chunks(ruby, rbs: rbs)["app/app.rb:27:2"]
  end
end

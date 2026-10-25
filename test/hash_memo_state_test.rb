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

  def returns(ruby, rbs:)
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      return Steep::Specializations::Runner.new(setup_project).run
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

  READERS_RBS = RBS.sub("class Car < Base\nend", "class Car < Base\n  def wheel: () -> Symbol\n  def seat: () -> Symbol\nend")
                   .sub("class Truck < Base\nend", "class Truck < Base\n  def seat: () -> Symbol\nend")

  READERS = RUBY.sub("  define_named :seat\nend", "  define_named :seat\n\n  def wheel = self.class.lookup(:wheel)\n  def seat = self.class.lookup(:seat)\nend")
                .sub("  define_named :seat\nend\n", "  define_named :seat\n\n  def seat = self.class.lookup(:seat)\nend\n")

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

  def test_a_reader_of_the_same_name_on_another_class_leaves_the_hash_known
    ruby = RUBY + "\nclass Directory\n  def registry = {}\nend\n\nclass Lister\n  def self.dump(directory) = directory.registry.clear\nend\n"

    { "::Directory" => ["def round; end"], "untyped" => [nil] }.each do |receiver, chunk|
      rbs = RBS + "class Directory\n  def registry: () -> Hash[Symbol, Symbol]\nend\nclass Lister\n  def self.dump: (#{receiver} directory) -> untyped\nend\n"

      assert_equal chunk, chunks(ruby, rbs: rbs)["app/app.rb:22:2"], receiver
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

  def test_asking_for_a_literal_key_answers_whether_the_hash_holds_it
    ruby = READERS.sub("    registry[name]\n", "    registry.key?(name) ? registry[name] : :none\n")
                  .sub(/  def seat = self\.class\.lookup\(:seat\)\nend\n\z/, "  def seat = self.class.lookup(:seat)\n  def wheel = self.class.lookup(:wheel)\nend\n")
    rbs = READERS_RBS.sub("class Truck < Base\n  def seat: () -> Symbol\nend", "class Truck < Base\n  def seat: () -> Symbol\n  def wheel: () -> Symbol\nend")
    lookup = returns(ruby, rbs: rbs)["Base.lookup"]

    assert_equal ":round", lookup["(:wheel) on singleton(::Car)"]
    assert_equal ":none", lookup["(:wheel) on singleton(::Truck)"]
  end

  def test_an_object_built_with_a_block_may_reach_the_class
    rbs = RBS.sub("class Car < Base", "class Maker\n  def initialize: () { () -> void } -> void\nend\nclass Car < Base")
    ruby = RUBY.sub("class Car < Base", "class Maker\n  def initialize = yield\nend\n\nclass Car < Base")
               .sub("  register :seat, :soft\n", "  register :seat, :soft\n  Maker.new { register :wheel, :flat }\n")

    assert_equal [nil], chunks(ruby, rbs: rbs)["app/app.rb:27:2"]
  end

  def test_an_object_built_with_a_callable_it_runs_may_reach_the_class
    rbs = RBS.sub("class Car < Base", "class Maker\n  def initialize: (^() -> void) -> void\nend\nclass Car < Base")
    ruby = RUBY.sub("class Car < Base", "class Maker\n  def initialize(f) = f.call\nend\n\nclass Car < Base")

    {
      "an inline lambda" => "  Maker.new(-> { register :wheel, :flat })\n",
      "a lambda held in a local" => "  later = -> { register :wheel, :flat }\n  Maker.new(later)\n"
    }.each do |shape, call|
      source = ruby.sub("  register :seat, :soft\n", "  register :seat, :soft\n#{call}")
      line = source.lines.index { |text| text.include?("define_named :wheel") } + 1

      assert_equal [nil], chunks(source, rbs: rbs)["app/app.rb:#{line}:2"], shape
    end
  end

  def test_a_method_reads_what_its_class_body_stored
    assert_equal(
      {
        "(:wheel) on singleton(::Car)" => ":round", "(:seat) on singleton(::Car)" => ":soft", "(:seat) on singleton(::Truck)" => ":bench",
        "(:wheel) on singleton(::Car) with {@registry: { :seat => :soft, :wheel => :round }}" => ":round",
        "(:wheel) with {@registry: { :seat => :soft, :wheel => :round }}" => ":round",
        "(:seat) on singleton(::Car) with {@registry: { :seat => :soft, :wheel => :round }}" => ":soft",
        "(:seat) with {@registry: { :seat => :soft, :wheel => :round }}" => ":soft",
        "(:seat) on singleton(::Truck) with {@registry: { :seat => :bench }}" => ":bench",
        "(:seat) with {@registry: { :seat => :bench }}" => ":bench"
      },
      returns(READERS, rbs: READERS_RBS)["Base.lookup"]
    )
  end

  def test_a_subclass_that_stores_nothing_adds_nil
    ruby = READERS + "\nclass SportsCar < Car\nend\n"
    rbs = READERS_RBS + "class SportsCar < Car\nend\n"

    assert_equal "(:round | nil)", returns(ruby, rbs: rbs)["Base.lookup"]["(:wheel) on singleton(::Car)"]
  end

  def test_declines_a_hash_a_store_may_reach_after_the_class_bodies
    {
      "a class method called from a method" => ["  def self.add_door = register(:wheel, :flat)\n", "  def refit = self.class.add_door\n"],
      "a store made inside a block" => ["  def self.add_all(names) = names.each { |name| register(name, :flat) }\n", ""],
      "a store reached by name" => ["", "  def refit = self.class.send(:register, :wheel, :flat)\n"],
      "a hook the runtime calls in a class body" => ["  def self.method_added(name)\n    super\n    register(:wheel, :added)\n  end\n", ""],
      "a store made through a safe navigation" => ["", "  def refit = self.class.registry&.store(:wheel, :flat)\n"],
      "a storing method called by an alias" => ["  class << self\n    alias add register\n  end\n", "  def refit = self.class.add(:wheel, :flat)\n"],
      "a storing method aliased by a call" => ["  singleton_class.alias_method :add, :register\n", "  def refit = self.class.add(:wheel, :flat)\n"],
      "an operator the runtime calls" => ["  def self.===(other)\n    register(:wheel, :flat)\n    super\n  end\n", "  def refit\n    case 1\n    when Car then 1\n    end\n  end\n"],
      "a hook the runtime calls in a method" => ["  def self.const_missing(name) = register(:wheel, :flat)\n", "  def refit = Car::Missing\n"]
    }.each do |shape, (class_method, method)|
      ruby = READERS.sub("  def self.lookup(name)", "#{class_method}  def self.lookup(name)").sub("  def wheel =", "#{method}  def wheel =")
      rbs = READERS_RBS.sub("    def self.lookup:", "    def self.add_door: () -> untyped\n    def self.add_all: (Array[Symbol]) -> untyped\n    def self.add: (Symbol, Symbol) -> untyped\n    def self.lookup:")
                       .sub("  def wheel: () -> Symbol", "  def refit: () -> untyped\n  def wheel: () -> Symbol")

      assert_nil returns(ruby, rbs: rbs)&.dig("Base.lookup", "(:wheel) on singleton(::Car)"), shape
    end
  end

  def test_declines_a_class_whose_body_is_written_twice
    ruby = READERS + "\nclass Car\n  register :door, :sliding\nend\n"

    assert_nil returns(ruby, rbs: READERS_RBS)&.dig("Base.lookup", "(:wheel) on singleton(::Car)")
  end
end

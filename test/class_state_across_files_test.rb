require_relative "test_helper"
require_relative "specializations_project_helper"

class ClassStateAcrossFilesTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  DEFINITIONS = <<~'RUBY'
    class Rules
      attr_reader :singulars

      def initialize
        @singulars = []
      end

      def singular(rule, replacement)
        @singulars.prepend([rule, replacement])
      end
    end

    class Holder
      def self.instances = @instances ||= {}
      def self.instance(locale = :en) = (instances[locale] ||= Rules.new)

      def self.singularize(word)
        result = word.dup
        instance(:en).singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end
    end

    module Inf
      def self.inflections(locale = :en)
        yield Holder.instance(locale) if block_given?
      end
    end
  RUBY

  RULES = <<~'RUBY'
    module Boot
      Inf.inflections(:en) { |i| i.singular(/s\z/, "") }
    end
  RUBY

  MACRO = <<~'RUBY'
    class Post
      def self.m(name) = class_eval("def #{Holder.singularize(name.to_s)}_ids; []; end")
      m :posts
    end
  RUBY

  WRITER = <<~'RUBY'
    module Late
      Inf.inflections(:en) { |i| i.singular(/ts\z/, "") }
    end
  RUBY

  RBS = <<~RBS
    class Rules
      attr_reader singulars: Array[untyped]
      def initialize: () -> Array[untyped]
      def singular: (untyped rule, untyped replacement) -> Array[untyped]
    end
    class Holder
      self.@instances: Hash[Symbol, Rules]?
      def self.instances: () -> Hash[Symbol, Rules]
      def self.instance: (?Symbol locale) -> Rules
      def self.singularize: (String word) -> String
    end
    module Inf
      def self.inflections: (?Symbol locale) ?{ (Rules) -> void } -> untyped
    end
    module Boot
    end
    module Late
    end
    class Post
      def self.m: (Symbol name) -> untyped
    end
  RBS

  CURRENT = DEFINITIONS.sub("  def self.instances", "  def self.current = @main ||= allocate\n  def self.instances")

  CURRENT_RBS = RBS.sub("  self.@instances", "  self.@main: Holder?\n  def self.current: () -> Holder\n  def self.reset: () -> Holder\n  self.@instances") + <<~RBS
    module Touch
      def self.touch: () -> Holder
    end
  RBS

  BACKED = DEFINITIONS.sub("class Holder\n", <<~'RUBY').sub("instances[locale] ||= Rules.new", "@instances[locale] ||= Rules.new").sub("  def self.instances = @instances ||= {}\n", "")
    class Backend
      def initialize
        @backend = {}
      end

      def [](key) = @backend[key]

      def []=(key, value)
        @backend[key] = value
      end
    end

    class Map < Backend
    end

    class Holder
      @instances = Map.new
  RUBY

  BACKED_RBS = RBS.sub("class Holder\n  self.@instances: Hash[Symbol, Rules]?\n  def self.instances: () -> Hash[Symbol, Rules]\n", <<~RBS)
    class Backend
      @backend: Hash[untyped, untyped]
      def initialize: () -> void
      def []: (untyped key) -> untyped
      def []=: (untyped key, untyped value) -> untyped
    end
    class Map < Backend
    end
    class Holder
      self.@instances: Map
  RBS

  def chunks(files, rbs = RBS, hooks = nil, &recorded)
    in_tmpdir do
      write("sig/app.rbs", rbs)
      files.each { |name, content| write("app/#{name}", content) }
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.singleton_class.prepend(Module.new { define_method(:file_check) { |*args| super(*args).tap { |typing| recorded&.call(args[2].path, typing) if typing } } })
      runner.singleton_class.prepend(hooks) if hooks
      runner.run
      runner.evals.values.flatten.map { |chunk| chunk&.source }
    end
  end

  def test_a_macro_in_another_file_reads_what_the_defining_file_left
    assert_equal ["def post_ids; []; end"], chunks("a.rb" => DEFINITIONS + RULES, "z.rb" => MACRO)
  end

  def test_a_macro_in_a_file_named_first_reads_what_the_defining_file_left
    assert_equal ["def post_ids; []; end"], chunks("z.rb" => DEFINITIONS + RULES, "a.rb" => MACRO)
  end

  def test_the_defining_file_keeps_leaving_a_hash_memo_an_object_holds
    holder = ::RBS::TypeName.parse("::Holder")
    left = [] #: Array[bool]
    folded = chunks({ "a.rb" => BACKED + RULES, "z.rb" => MACRO }, BACKED_RBS) do |path, typing|
      left << typing.top_level_states[1].key?(holder) if path.basename.to_s == "a.rb" && typing.top_level_states
    end

    assert_equal ["def post_ids; []; end"], folded
    assert_equal [], left.drop_while { |kept| !kept }.reject { |kept| kept }
  end

  def test_a_demanded_check_whose_answers_hold_is_kept_across_generations
    checks = Hash.new(0)
    counting = Module.new do
      define_method(:demand_exit) do |*args|
        @demanding_depth = (@demanding_depth || 0) + 1
        super(*args)
      ensure
        @demanding_depth -= 1
      end
      define_method(:type_check) do |context, store, source, active|
        active.each_value { |arguments| checks[arguments.key] += 1 } if @demanding_depth&.positive?
        super(context, store, source, active)
      end
    end

    assert_equal ["def post_ids; []; end"], chunks({ "a.rb" => BACKED + RULES, "z.rb" => MACRO }, BACKED_RBS, counting)
    assert_equal 1, checks['(/s\z/, "") with {@singulars: []}']
  end

  def test_the_classes_a_method_names_are_walked_once_per_method_and_store
    walks = Hash.new(0)
    counting = Module.new do
      define_method(:visit_named) do |constr, owner, method_name, singleton, names, seen|
        family = constr.specializations.keep(:family) { Object.new }
        walks[[family, owner, method_name, singleton]] += 1 if seen.empty? && Thread.current[:count_named_walks]
        super(constr, owner, method_name, singleton, names, seen)
      end
    end
    Steep::ObjectStates::ClassStates.singleton_class.prepend(counting)
    Thread.current[:count_named_walks] = true

    assert_equal ["def post_ids; []; end"], chunks("a.rb" => DEFINITIONS + RULES, "z.rb" => MACRO)
    refute_empty walks
    assert_equal [1], walks.values.uniq
  ensure
    Thread.current[:count_named_walks] = nil
  end

  def test_the_calls_on_a_receiver_are_sorted_once_per_method_and_store
    sorts = Hash.new(0)
    asking = Module.new do
      define_method(:calls_on) do |constr, name, target|
        Thread.current[:asked_calls_on] = [constr.specializations.keep(:family) { Object.new }, name, target]
        super(constr, name, target)
      ensure
        Thread.current[:asked_calls_on] = nil
      end
    end
    sorting = Module.new do
      define_method(:calls_of) { |name| super(name).tap { sorts[Thread.current[:asked_calls_on]] += 1 if Thread.current[:asked_calls_on] } }
    end
    Steep::Specializations::Receivers.singleton_class.prepend(asking)
    Steep::Project::ConstructorBindingRegistry.prepend(sorting)

    assert_equal ["def post_ids; []; end"], chunks("a.rb" => DEFINITIONS + RULES, "z.rb" => MACRO)
    refute_empty sorts
    assert_equal [1], sorts.values.uniq
  end

  def test_declines_what_a_file_other_than_the_defining_one_writes
    assert_equal [nil], chunks("a.rb" => DEFINITIONS, "b.rb" => RULES, "c.rb" => MACRO)
  end

  def test_declines_a_class_another_file_writes_after_its_definition
    assert_equal [nil], chunks("a.rb" => DEFINITIONS + RULES, "b.rb" => WRITER, "c.rb" => MACRO)
  end

  def test_declines_a_class_another_file_reopens
    reopened = "class Holder\n  instance(:en).singular(/ts\\z/, \"\")\nend\n"
    assert_equal [nil], chunks("a.rb" => DEFINITIONS + RULES, "b.rb" => reopened, "c.rb" => MACRO)
  end

  def test_declines_a_class_another_file_reopens_in_a_block
    reopened = "[1].each do\n  class Holder\n    instance(:en).singular(/ts\\z/, \"\")\n  end\nend\n"
    assert_equal [nil], chunks("a.rb" => DEFINITIONS + RULES, "b.rb" => reopened, "c.rb" => MACRO)
  end

  def test_a_memo_of_allocate_another_file_runs_keeps_the_class_carried
    touch = "module Touch\n  Holder.current\nend\n"
    assert_equal ["def post_ids; []; end"], chunks({ "a.rb" => CURRENT + RULES, "b.rb" => touch, "c.rb" => MACRO }, CURRENT_RBS)
  end

  def test_a_memo_of_allocate_another_file_runs_through_a_method_keeps_the_class_carried
    touch = "module Touch\n  def self.touch = Holder.current\n  touch\nend\n"
    assert_equal ["def post_ids; []; end"], chunks({ "a.rb" => CURRENT + RULES, "b.rb" => touch, "c.rb" => MACRO }, CURRENT_RBS)
  end

  def test_a_memo_of_allocate_a_call_with_no_known_exit_runs_keeps_the_class_carried
    touch = "module Touch\n  def self.inner(*names) = Holder.current\n  def self.touch(*names) = inner(*names)\n  touch(*%i[a])\nend\n"
    rbs = CURRENT_RBS.sub("def self.touch: () -> Holder", "def self.touch: (*Symbol names) -> Holder\n  def self.inner: (*Symbol names) -> Holder")
    assert_equal ["def post_ids; []; end"], chunks({ "a.rb" => CURRENT + RULES, "b.rb" => touch, "c.rb" => MACRO }, rbs)
  end

  def test_declines_a_memo_of_allocate_another_method_reads
    started = CURRENT.sub("  def self.instances", "  def self.started = @main ? :started : :fresh\n  def self.instances")
    touch = "module Touch\n  Holder.current\nend\n"
    macro = "class Post\n  def self.m(name) = class_eval(\"def \#{Holder.started}_\#{name}; end\")\n  m :posts\nend\n"
    rbs = CURRENT_RBS.sub("  def self.reset: () -> Holder", "  def self.started: () -> Symbol")
    assert_equal [nil], chunks({ "a.rb" => started + RULES, "b.rb" => touch, "c.rb" => macro }, rbs)
  end
end

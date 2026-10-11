require_relative "test_helper"

class ClassBodyStateTest < Minitest::Test
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

  def chunks(rbs, ruby)
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
    class Settings
      attr_accessor name: Symbol
    end
    class Base
      self.@settings: Settings?
      def self.settings: () -> Settings
      def self.define_named: () -> untyped
    end
    class Article < Base
    end
  RBS

  def test_a_state_set_in_the_class_body_reaches_a_macro_called_after_it
    evals = chunks(RBS, <<~'RUBY')
      class Settings
        attr_accessor :name
      end

      class Base
        def self.settings = @settings ||= Settings.new
        def self.define_named = class_eval("def #{settings.name}; end")
      end

      class Article < Base
        settings.name = :posts
        define_named
        settings.name = :comments
        define_named
      end
    RUBY

    assert_equal({ "app/app.rb:12:2" => ["def posts; end"], "app/app.rb:14:2" => ["def comments; end"] }, evals)
  end

  def source(extra_base: "", article:, settings: "attr_accessor :name", memo: "def self.settings = @settings ||= Settings.new")
    <<~RUBY
      class Settings
      #{settings.gsub(/^/, "  ")}
      end

      class Base
      #{memo.gsub(/^/, "  ")}
        def self.define_named = class_eval("def \#{settings.name}; end")
      #{extra_base.gsub(/^/, "  ")}
      end

      class Article < Base
      #{article.gsub(/^/, "  ")}
      end
    RUBY
  end

  def test_each_class_body_has_its_own_object
    evals = chunks(RBS + "class Comment < Base\nend\n", source(article: "settings.name = :posts\ndefine_named") + <<~'RUBY')
      class Comment < Base
        settings.name = :replies
        define_named
      end
    RUBY

    assert_equal [["def posts; end"], ["def replies; end"]], evals.values
  end

  def test_a_read_before_the_object_is_set_up_is_a_hole
    assert_equal [[nil]], chunks(RBS, source(article: "define_named\nsettings.name = :posts")).values
  end

  def test_declines_an_object_something_else_may_reach
    {
      "another name for it" => ["def self.copy = (kept = settings; kept)", ""],
      "a change made outside a class body" => ["def self.rename = settings.name = :other", ""],
      "a change made inside a block" => ["", "[1].each { settings.name = :other }"],
      "a second write to the ivar" => ["def self.reset = @settings = Settings.new", ""],
      "the object handed on" => ["def self.keep = Kernel.p(settings)", ""],
      "its name as a value" => ["def self.peek = send(:settings)", ""]
    }.each do |label, (extra_base, extra_article)|
      article = "settings.name = :posts\n#{extra_article}\ndefine_named"
      assert_equal [[nil]], chunks(RBS, source(extra_base: extra_base, article: article)).values, label
    end
  end

  def test_a_memo_written_in_class_self
    memo = "class << self\n  def settings = @settings ||= Settings.new\nend"

    assert_equal [["def posts; end"]], chunks(RBS, source(memo: memo, article: "settings.name = :posts\ndefine_named")).values
  end

  def test_declines_an_object_its_initialize_hands_on
    rbs = RBS.sub("attr_accessor name: Symbol", "ALL: Array[Settings]\n  attr_accessor name: Symbol\n  def initialize: () -> void")
    settings = "ALL = []\nattr_accessor :name\ndef initialize = ALL << self"
    article = "settings.name = :posts\nSettings::ALL.each { |s| s.name = :other }\ndefine_named"

    assert_equal [[nil]], chunks(rbs, source(settings: settings, article: article)).values
  end

  def test_a_name_no_call_reaches_the_memo_by_is_no_use_of_it
    rbs = RBS + "class Routes\n  def draw: () -> untyped\n  def resources: (Symbol) -> untyped\nend\n" \
                "class Panel\n  @settings: Integer\n  def show: () -> Integer\nend\n"
    others = "class Routes\n  def draw = resources(:settings)\n  def resources(name) = name\nend\n" \
             "class Panel\n  def show = @settings = 1\nend\n"

    assert_equal [["def posts; end"]], chunks(rbs, source(article: "settings.name = :posts\ndefine_named") + others).values
  end

  def test_a_string_only_where_its_source_freezes_it
    rbs = RBS.sub("attr_accessor name: Symbol", "attr_accessor name: String")
    ruby = source(article: "settings.name = \"posts\"\ndefine_named")

    assert_equal [["def posts; end"]], chunks(rbs, "# frozen_string_literal: true\n#{ruby}").values
    assert_equal [[nil]], chunks(rbs, ruby).values
  end
end

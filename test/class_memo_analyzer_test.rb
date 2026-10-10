require_relative "test_helper"

class ClassMemoAnalyzerTest < Minitest::Test
  def scan(source)
    Steep::TypeInference::ClassMemoAnalyzer.scan(Steep::Source.new_parser.parse(Parser::Source::Buffer.new("a.rb", source: source)))
  end

  def uses(scan, name)
    scan.uses[name].map { |use| [use.kind, use.called] }
  end

  def test_a_memo_built_with_new
    memos = scan(<<~RUBY).memos
      class Base
        def self.settings = @settings ||= Settings.new
        def self.computed = @computed ||= compute
        def self.argued = @argued ||= Settings.new(1)
      end
    RUBY

    assert_equal [[:@settings, "Settings"]], memos.dig("Base", :settings)
    assert_equal [nil], memos.dig("Base", :computed)
    assert_equal [nil], memos.dig("Base", :argued)
  end

  def test_each_use_by_what_it_is
    scan = scan(<<~RUBY)
      class Article < Base
        settings.name = :posts
        self.settings.label = :x
        settings.name = :other if flag
        def self.read = settings.name
        def self.keep = Kernel.p(settings)
      end
    RUBY

    assert_equal [[:statement, :name=], [:statement, :label=], [:receiver, :name=], [:receiver, :name], [:escape, nil]], uses(scan, :settings)
  end

  def test_the_ivar_written_outside_its_memo_and_its_name_as_a_value
    scan = scan(<<~RUBY)
      class Base
        def self.settings = @settings ||= Settings.new
        def self.reset = @settings = nil
        def self.peek = instance_variable_get(:@settings)
      end
    RUBY

    assert_equal [[:escape, nil], [:escape, nil]], uses(scan, :@settings)
  end
end

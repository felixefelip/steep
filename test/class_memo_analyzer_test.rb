require_relative "test_helper"

class ClassMemoAnalyzerTest < Minitest::Test
  def parse(source)
    Steep::Source.new_parser.parse(Parser::Source::Buffer.new("a.rb", source: source))
  end

  def uses(source, name)
    Steep::TypeInference::ClassMemoAnalyzer.uses(parse(source), names: Set[:settings, :@settings])
      .fetch(name, []).map { |use| [use.kind, use.called] }
  end

  def test_a_memo_built_with_new_is_a_body_s_memo
    methods = Steep::TypeInference::ConstructorBindingAnalyzer.scan(parse(<<~RUBY)).singleton_methods.fetch("Wrap::Base")
      module Wrap
        class Base
          def self.settings = @settings ||= Settings.new
          def self.computed = @computed ||= compute
          def self.argued = @argued ||= Settings.new(1)

          class << self
            def nested = @nested ||= ::Settings.new
          end
        end
      end
    RUBY

    assert_equal [:@settings, %w[Wrap::Base::Settings Wrap::Settings Settings]], methods[:settings].first.memo
    assert_nil methods[:computed].first.memo
    assert_nil methods[:argued].first.memo
    assert_equal [:@nested, ["Settings"]], methods[:nested].first.memo
  end

  def test_each_use_by_what_it_is
    assert_equal [[:statement, :name=], [:statement, :label=], [:receiver, :name=], [:receiver, :name], [:escape, nil]], uses(<<~RUBY, :settings)
      class Article < Base
        settings.name = :posts
        self.settings.label = :x
        settings.name = :other if flag
        def self.read = settings.name
        def self.keep = Kernel.p(settings)
      end
    RUBY
  end

  def test_an_ivar_counts_only_where_self_may_be_a_class
    assert_equal [[:escape, nil], [:receiver, :name]], uses(<<~RUBY, :@settings)
      class Base
        def self.peek = @settings
        def show = @settings.name
        def each = items.each { @settings.name }
      end
    RUBY
  end

  def test_a_name_counts_only_where_a_call_reaches_it_by_name
    assert_equal [[:escape, nil], [:escape, nil], [:escape, nil]], uses(<<~'RUBY', :settings) + uses(<<~'RUBY', :@settings)
      class Base
        def self.peek = send(:settings)
        def self.run = class_eval("settings.name = :x")
        def self.routes = resources(:settings)
      end
    RUBY
      class Base
        def self.peek = instance_variable_get(:@settings)
      end
    RUBY
  end
end

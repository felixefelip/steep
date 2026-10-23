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
          def self.tapped = @tapped ||= Settings.new.tap { |settings| settings.name = :posts }
          def self.handed = @handed ||= Settings.new.tap(1) { |settings| settings }

          class << self
            def nested = @nested ||= ::Settings.new
          end
        end
      end
    RUBY

    assert_equal [:@settings, %w[Wrap::Base::Settings Wrap::Settings Settings], []], methods[:settings].first.memo
    assert_nil methods[:computed].first.memo
    assert_nil methods[:argued].first.memo
    assert_equal [:@tapped, %w[Wrap::Base::Settings Wrap::Settings Settings], [:tap]], methods[:tapped].first.memo
    assert_nil methods[:handed].first.memo
    assert_equal [:@nested, ["Settings"], []], methods[:nested].first.memo
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

  def test_a_local_assigned_once_is_used_where_it_is
    assert_equal [[:receiver, :fetch], [:receiver, :name], [:escape, nil], [:escape, nil], [:escape, nil]], uses(<<~RUBY, :settings)
      class Article < Base
        def self.read
          local = settings
          local.fetch(:through)
          [1].each { local.name }
        end
        def self.reassigned
          local = settings
          local = nil
          local&.name
        end
        def self.handed
          local = settings
          Kernel.p(local)
        end
        def self.returned
          local = settings
          local
        end
      end
    RUBY
  end

  def test_a_method_that_returns_the_use_forwards_it
    found = Steep::TypeInference::ClassMemoAnalyzer.uses(parse(<<~RUBY), names: Set[:settings]).fetch(:settings)
      class Article < Base
        def source_settings = source.settings
        def self.picked(flag)
          [1].each { return source.settings if flag }
          -> { return source.settings }
          kept = [source.settings]
          nil
        end
      end
    RUBY

    assert_equal [[:escape, :source_settings], [:escape, :picked], [:escape, nil], [:escape, nil]], found.map { |use| [use.kind, use.forwarded_by] }
  end

  def test_a_read_by_key_carries_the_uses_of_the_element_it_answers
    found = Steep::TypeInference::ClassMemoAnalyzer.uses(parse(<<~RUBY), names: Set[:instances]).fetch(:instances)
      class Inflector
        def self.instance(locale) = (instances[locale] ||= Rules.new)
        instances[:en].singular(1)
        def self.peek = instances[:en].size
      end
    RUBY

    assert_equal(
      [[:[]=, nil], [:[], [[:escape, nil, :instance]]], [:[], [[:statement, :singular, nil]]], [:[], [[:receiver, :size, nil]]]],
      found.map { |use| [use.called, use.value&.map { |value| [value.kind, value.called, value.forwarded_by] }] }
    )
  end

  def test_a_call_in_a_statement_of_a_class_body_is_made_by_the_class_body
    found = Steep::TypeInference::ClassMemoAnalyzer.calls(parse(<<~RUBY), names: Set[:instance]).fetch(:instance)
      class Inflector
        instance(:en).singular(1)
        def self.read = instance(:en).singulars.each { |rule| rule }
        on_load { instance(:en) }
      end
    RUBY

    assert_equal [[:statement, nil], [:call, :read], [:call, nil]], found.map { |call| [call.kind, call.within] }
  end

  def test_a_value_left_unused_is_no_use
    found = Steep::TypeInference::ClassMemoAnalyzer.uses(parse(<<~RUBY), names: Set[:settings]).fetch(:settings, [])
      class Article < Base
        settings { |value| value }
        def self.wrapped
          settings
          nil
        end
      end
    RUBY

    assert_equal [], found
  end

  def test_a_call_on_the_value_as_written_is_direct
    found = Steep::TypeInference::ClassMemoAnalyzer.uses(parse(<<~RUBY), names: Set[:settings]).fetch(:settings)
      class Article < Base
        def self.write(source)
          source.settings[:a] = 1
          local = source.settings
          local[:a] = 1
          source.settings[:a] += 1
          source.settings[:a], other = 1, 2
        end
      end
    RUBY

    assert_equal [[:[]=, true], [:[]=, false], [:[]=, nil], [:[], false], [:[]=, false]], found.map { |use| [use.called, use.direct] }
  end

  def test_an_operator_assignment_counts_its_writer_too
    assert_equal [[:receiver, :[]=], [:receiver, :[]], [:receiver, :name=], [:receiver, :name], [:receiver, :[]=], [:receiver, :[]]],
                 uses(<<~RUBY, :settings) + uses(<<~RUBY, :@settings)
                   class Article < Base
                     settings[:a] ||= 1
                     settings.name += "x"
                   end
                 RUBY
                   class Base
                     def self.fill = @settings[:a] &&= 2
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

  def test_an_iteration_counts_only_while_its_block_reads_the_elements
    found = Steep::TypeInference::ClassMemoAnalyzer.uses(parse(<<~'RUBY'), names: Set[:singulars])
      class Base
        def self.a = rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        def self.b = rules.singulars.map { |(rule, _)| "#{rule}" }
        def self.c = rules.singulars.each { |(_, replacement)| replacement << "x" }
        def self.d = rules.singulars.each { |pair| log(pair) }
        def self.e = rules.singulars.each
        def self.f = rules.singulars.size
      end
    RUBY

    assert_equal [[:receiver, :each], [:receiver, :map], [:escape, nil], [:escape, nil], [:escape, nil], [:receiver, :size]],
                 found.fetch(:singulars).map { |use| [use.kind, use.called] }
  end

  def test_a_use_on_self_names_the_class_method_making_it
    source = <<~RUBY
      class Base
        def self.register(name, value) = settings[name] = value
        def self.each_register(names) = names.each { |name| settings[name] = 1 }
        def other = settings[:a] = 1

        class << self
          def nested(name) = settings&.store(name, 1)
        end
      end
    RUBY
    found = Steep::TypeInference::ClassMemoAnalyzer.uses(parse(source), names: Set[:settings]).fetch(:settings)

    assert_equal [[:[]=, :register], [:[]=, nil], [:[]=, nil], [:store, :nested]], found.map { |use| [use.called, use.within] }
  end

  def test_each_call_of_a_method_by_where_it_is_made
    source = <<~RUBY
      class Car < Base
        register :wheel, 1
        Truck.register :spare, 1
        def self.refit = register(:door, 1)
        def fit = self.class.send(:register, :seat, 1)
      end
    RUBY
    found = Steep::TypeInference::ClassMemoAnalyzer.calls(parse(source), names: Set[:register]).fetch(:register)

    assert_equal [[:statement, nil], [:call, nil], [:call, :refit], [:escape, nil]], found.map { |use| [use.kind, use.within] }
  end
end

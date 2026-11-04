require_relative "test_helper"
require_relative "specializations_project_helper"

class I18nFallbacksTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    module I18n
      module Locale
        module Tag
          @@implementation: singleton(Simple)
          def self.implementation: () -> singleton(Simple)
          def self.implementation=: (singleton(Simple) implementation) -> singleton(Simple)
          def self.tag: (Symbol | String tag) -> Simple
          interface _Tag
            def to_a: () -> Array[String]
          end
          module Parents
            @parent: Simple?
            @parents: Array[Simple]
            @self_and_parents: Array[Simple]
            def parent: () -> Simple?
            def self_and_parents: () -> Array[Simple]
            def parents: () -> Array[Simple]
          end
          class Simple
            include Parents
            @tag: Symbol
            @subtags: Array[String]
            def self.tag: (Symbol | String tag) -> Simple
            def initialize: (*(Symbol | String) tag) -> void
            attr_reader tag: Symbol
            def subtags: () -> Array[String]
            def to_sym: () -> Symbol
            def to_s: () -> String
            def to_a: () -> Array[String]
          end
        end
      end
    end
    module I18n
      module Locale
        class Fallbacks < Hash[Symbol, Array[Symbol]]
          @map: Hash[Symbol, Array[Symbol]]
          @defaults: Array[Symbol]
          def initialize: (*untyped mappings) -> void
          def defaults=: (Array[Symbol | String] defaults) -> Array[Symbol]
          attr_reader defaults: Array[Symbol]
          def map: (*untyped args) ?{ (*untyped) -> untyped } -> untyped
          def compute: (Symbol | String | Array[Symbol | String] | nil tags, ?bool include_defaults, ?Array[Symbol] exclude) -> Array[Symbol]
          def en: () -> untyped
          def fr: () -> untyped
          def fr_ca: () -> untyped
          def fr_ca_bare: () -> untyped
        end
      end
    end
    class P
      def en_fallbacks: () -> untyped
      def fr_fallbacks: () -> untyped
      def fr_ca_fallbacks: () -> untyped
      def fr_ca_fallbacks_without_defaults: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    module I18n
      module Locale
        module Tag
          class << self
            def implementation
              @@implementation ||= Simple
            end

            def implementation=(implementation)
              @@implementation = implementation
            end

            def tag(tag)
              implementation.tag(tag)
            end
          end

          module Parents
            # @type instance: Simple & Parents

            def parent
              @parent ||=
                begin
                  segs = to_a
                  segs.compact!
                  segs.length > 1 ? self.class.tag(*segs[0..(segs.length - 2)].join('-')) : nil
                end
            end

            def self_and_parents
              @self_and_parents ||= [self].concat parents
            end

            def parents
              @parents ||= parent ? [parent].concat(parent.parents) : []
            end
          end

          class Simple
            class << self
              def tag(tag)
                new(tag)
              end
            end

            include Parents

            attr_reader :tag

            def initialize(*tag)
              @tag = tag.join('-').to_sym
            end

            def subtags
              @subtags = tag.to_s.split('-').map!(&:to_s)
            end

            def to_sym
              tag
            end

            def to_s
              tag.to_s
            end

            def to_a
              subtags
            end
          end
        end
      end
    end

    module I18n
      module Locale
        class Fallbacks < Hash
          def initialize(*mappings)
            @map = {}
            map(mappings.pop) if mappings.last.is_a?(Hash)
            self.defaults = mappings.empty? ? [] : mappings
          end

          def defaults=(defaults)
            @defaults = defaults.flat_map { |default| compute(default, false) }
          end
          attr_reader :defaults

          def map(*args, &block)
            if args.count == 1 && !block_given?
              mappings = args.first
              mappings.each do |from, to|
                from, to = from.to_sym, Array(to)
                to.each do |_to|
                  @map[from] ||= []
                  @map[from] << _to.to_sym
                end
              end
            else
              @map.map(*args, &block)
            end
          end

          protected

          def compute(tags, include_defaults = true, exclude = [])
            result = []
            Array(tags).each do |tag|
              tags = I18n::Locale::Tag.tag(tag).self_and_parents.map! { |t| t.to_sym } - exclude
              result += tags
              tags.each { |_tag| result += compute(@map[_tag], false, exclude + result) if @map[_tag] }
            end

            result.push(*defaults) if include_defaults
            result.uniq!
            result.compact!
            result
          end

          public

          def en = compute(:en)
          def fr = compute(:fr)
          def fr_ca = compute(:"fr-CA")
          def fr_ca_bare = compute(:"fr-CA", false)
        end
      end
    end

    class P
      def en_fallbacks = I18n::Locale::Fallbacks.new.en
      def fr_fallbacks = I18n::Locale::Fallbacks.new.fr
      def fr_ca_fallbacks = I18n::Locale::Fallbacks.new.fr_ca
      def fr_ca_fallbacks_without_defaults = I18n::Locale::Fallbacks.new.fr_ca_bare
    end
  RUBY

  def types
    in_tmpdir do
      write("sig/p.rbs", RBS)
      write("app/p.rb", RUBY)
      project = setup_project
      postconditions = Steep::Postconditions::Runner.new(project)
      postconditions.write(postconditions.run)
      project = setup_project
      runner = Steep::Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!
      return body_types(project, current_dir + "app/p.rb")
    end
  end

  def test_compute_folds_a_locale_and_its_parents_for_a_fallbacks_with_no_mappings
    found = types

    assert_equal "[:en]", found.fetch("en_fallbacks")
    assert_equal "[:fr]", found.fetch("fr_fallbacks")
    assert_equal "[:\"fr-CA\", :fr]", found.fetch("fr_ca_fallbacks")
    assert_equal "[:\"fr-CA\", :fr]", found.fetch("fr_ca_fallbacks_without_defaults")
  end
end

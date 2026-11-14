require_relative "test_helper"
require_relative "specializations_project_helper"

class SpecializationsClosedProcTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  Specializations = Steep::Specializations

  RBS = <<~RBS
    class Keys
      def self.inner: (^(Symbol) -> String proc, Symbol key) -> String
      def self.outer: (Symbol key) { (Symbol) -> String } -> String
      def self.yielding: (Symbol key) { (Symbol) -> String } -> String
      def self.forwarding: (Symbol key) { (Symbol) -> String } -> String
    end
    class Box
      @proc: ^(Symbol) -> String
      def initialize: () { (Symbol) -> String } -> void
      def keep: (^(Symbol) -> String proc) -> void
      def get: (Symbol key) -> String
    end
    class Loose
      @proc: ^(untyped) -> untyped
      def initialize: () { (untyped) -> untyped } -> void
      def get: (Symbol key) -> untyped
    end
    class Shelf[V]
      @proc: ^(Symbol) -> V
      def initialize: () { (Symbol) -> V } -> void
      def get: (Symbol key) -> V
    end
    class Caller
      def loose: () -> untyped
      def shelved: () -> untyped
      def boxed: () -> String
      def handed: () -> String
      def lambda_literal: () -> String
      def forwarded: () -> String
      def reading_its_scope: () -> String
    end
  RBS

  def specialize(project, generations: 3)
    generations.times do
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!
    end
  end

  def caller_types(body)
    in_tmpdir do
      write("sig/keys.rbs", RBS)
      write("app/keys.rb", <<~RUBY)
        class Keys
          def self.inner(proc, key) = proc.call(key)
          def self.outer(key, &block) = inner(block, key)
          def self.yielding(key) = yield(key)
          def self.forwarding(key, &block) = yielding(key, &block)
        end

        class Box
          def initialize(&block)
            keep(block)
          end

          def keep(proc)
            @proc = proc
          end

          def get(key) = @proc.call(key)
        end

        class Loose
          def initialize(&block)
            @proc = block
          end

          def get(key) = @proc.call(key)
        end

        class Shelf
          def initialize(&block)
            @proc = block
          end

          def get(key) = @proc.call(key)
        end

        class Caller
          #{body}
        end
      RUBY
      project = setup_project
      specialize(project)
      yield project if block_given?
      body_types(project, current_dir + "app/keys.rb")
    end
  end

  def test_a_block_handed_on_as_an_argument_is_called_as_the_block
    assert_equal '"missing"', caller_types("def handed = Keys.outer(:missing) { |key| key.to_s }").fetch("handed")
  end

  def test_a_closed_lambda_passed_as_an_argument_is_called_as_its_body
    entries = nil
    types = caller_types("def lambda_literal = Keys.inner(->(key) { key.to_s }, :missing)") do |project|
      entries = Specializations::Runner.new(project).run.fetch("Keys.inner")
    end

    assert_equal '"missing"', types.fetch("lambda_literal")
    assert_match(/\A\(proc\(&\{\h{16}\}\), :missing\)\z/, entries.keys.first)
  end

  def test_a_block_forwarded_with_an_ampersand_is_yielded_as_the_block
    assert_equal '"missing"', caller_types("def forwarded = Keys.forwarding(:missing) { |key| key.to_s }").fetch("forwarded")
  end

  def test_a_proc_kept_in_an_ivar_is_called_as_the_block_from_another_method
    entries = nil
    types = caller_types("def boxed = Box.new { |key| key.to_s }.get(:missing)") do |project|
      entries = Specializations::Runner.new(project).run.fetch("Box.new")
    end

    assert_equal '"missing"', types.fetch("boxed")
    assert_equal({ "proc" => "^(::Symbol) -> ::String", "block" => "{ |key| key.to_s }" }, entries.values.first.dig("ivars", "@proc"))
  end

  def test_a_closed_block_returning_untyped_is_kept_as_the_block
    assert_equal '"missing"', caller_types("def loose = Loose.new { |key| key.to_s }.get(:missing)").fetch("loose")
  end

  def test_a_closed_block_kept_by_a_generic_class_answers_what_it_returns
    assert_equal '"missing"', caller_types("def shelved = Shelf.new { |key| key.to_s }.get(:missing)").fetch("shelved")
  end

  def test_a_node_a_check_rewrote_is_closed_only_where_its_source_is
    written = Steep::Source.new_parser.parse(::Parser::Source::Buffer.new("(test)", source: "proc { |key| upcased(key) }"))
    rewritten = written.updated(nil, [written.children[0], written.children[1], ::Parser::AST::Node.new(:lvar, [:key])])

    assert_nil Steep::ObjectStates::Yields.closed_params(written)
    assert_nil Steep::ObjectStates::Yields.closed_params(rewritten)
  end

  def test_a_lambda_reading_a_local_of_its_scope_answers_the_declaration
    body = <<~RUBY
      def reading_its_scope
        suffix = "!"
        Keys.inner(->(key) { key.to_s + suffix }, :missing)
      end
    RUBY
    assert_equal "::String", caller_types(body).fetch("reading_its_scope")
  end
end

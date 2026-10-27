require_relative "../test_helper"

class PostconditionsRunsBlockTest < Minitest::Test
  include TestHelper
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  RBS = <<~RBS
    class RBLock
      @count: Integer?
      def lock: () -> void
      def unlock: () -> void
      def locked?: () -> bool
      def synchronize: [T] () { () -> T } -> T
      def maybe: () { () -> untyped } -> untyped
      def twice: () { () -> untyped } -> untyped
      def never: () { () -> untyped } -> untyped
      def looped: () { () -> untyped } -> untyped
      def early: () { () -> untyped } -> untyped
      def rescued: () { () -> untyped } -> untyped
      def guarded: () { () -> untyped } -> untyped
      def counted: () { () -> untyped } -> untyped
    end
  RBS

  SOURCE = <<~RUBY
    class RBLock
      def synchronize
        raise ThreadError, "must be called with a block" unless block_given?
        lock
        begin
          yield
        ensure
          unlock
        end
      end

      def maybe
        yield if locked?
      end

      def twice
        yield
        yield
      end

      def never = nil

      def looped
        3.times { yield }
      end

      def early
        return if locked?
        yield
      end

      def rescued
        yield
      rescue StandardError
        nil
      end

      def guarded
        block_given? ? yield : raise(ArgumentError)
      end

      def counted
        @count = 1
        yield
      end
    end
  RUBY

  def runs_block
    with_checker({ "app.rbs" => RBS }, with_stdlib: true) do |checker|
      source = parse_ruby(SOURCE)
      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)
        entries = Steep::Postconditions::Inferrer.infer(source, typing, checker)
        store = Steep::Postconditions::Store.from_hash(YAML.safe_load(Steep::Postconditions::Writer.dump(entries)), source: "test")
        return %i[synchronize guarded counted maybe twice never looped early rescued].to_h { |name| [name, store.lookup_instance("RBLock", name)&.runs_block || false] }
      end
    end
  end

  def test_a_method_runs_its_block_once_where_every_way_out_but_a_raise_passes_one_yield
    assert_equal({ synchronize: true, guarded: true, counted: true, maybe: false, twice: false, never: false, looped: false, early: false, rescued: false }, runs_block)
  end
end

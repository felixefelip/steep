require_relative "test_helper"

class StoreKeptTest < Minitest::Test
  include FactoryHelper

  def store(receivers = {}, kept: {})
    Steep::Specializations::Store.new(methods: {}, source: nil, receivers: receivers, bodies: {}, kept: kept)
  end

  def test_a_kept_value_is_computed_once_across_the_copies_of_a_store
    original = store
    computed = 0
    [original, original.with_reads(Steep::Specializations::Reads.new), original.with_active({ ["a.rb", 0] => nil })].each do |copy|
      copy.keep([:closure, :run]) { computed += 1 }
    end

    assert_equal 1, computed
  end

  def test_a_store_built_apart_keeps_its_own_values
    computed = 0
    [store, store].each { |apart| apart.keep([:closure, :run]) { computed += 1 } }

    assert_equal 2, computed
  end

  def test_a_receiver_is_parsed_once_however_often_a_check_asks_for_it
    with_factory do |factory|
      parsed = 0
      counting = Module.new { define_method(:parse) { |*args, **opts| parsed += 1 if args[0] == "app/a.rb:1"; super(*args, **opts) } }
      original = store({ "app/a.rb:1" => ["::Integer"] })
      original.singleton_class.prepend(counting)
      reads = Steep::Specializations::Reads.new
      reading = original.with_reads(reads)
      reading.singleton_class.prepend(counting)

      type = reading.receiver_type("app/a.rb:1", factory: factory)
      assert reads.same?(reading)

      assert_equal "::Integer", type.to_s
      assert_equal 1, parsed
    end
  end
end

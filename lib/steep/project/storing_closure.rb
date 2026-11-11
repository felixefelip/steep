module Steep
  class Project
    class ConstructorBindingRegistry
      # The methods a call of which may run a store into a hash memo, by name,
      # and whether `new` may, through an `initialize` that does. `owners`: the
      # classes whose method of each name it holds, as `[class_name,
      # singleton]` (`ConstructorBindingRegistry#owners_of`).
      StoringClosure = Struct.new(:methods, :constructs, :owners) do
        # The closure of the methods `owners` holds: every method that makes
        # a call `reaching` one of them, by the classes whose method of that
        # name it holds; nil where such a call is made from code no method
        # stands for. A call inside blocks stands for the method holding them
        # where `in_place` says each block runs before its call returns.
        # `calls_named` answers every call of the names given.
        def self.grow(owners, reaching:, in_place:, &calls_named)
          escaped = false
          loop do
            closure = new(owners.keys.to_set - [:initialize], owners.key?(:initialize), owners)
            named = calls_named.call(closure.constructs ? owners.keys | [:new] : owners.keys)
            calls = closure.reached(named.reject { |call| call.kind == :escape }, reaching)
            made_in = calls.to_h { |call| [call, made_in(call, in_place)] }
            escaped ||= named.any? { |call| call.kind == :escape } || calls.any? { |call| !(call.in_class_body || made_in[call]) }

            grown = made_in.values.compact.reject { |name, method| owners.fetch(name, Set[]).include?(method) }
            return (closure unless escaped) if grown.empty?

            owners = owners.merge(grown.group_by(&:first).transform_values { |found| found.to_set(&:last) }) { |_, old, new| old | new }
          end
        end

        # `[name, [owner, singleton]]` of the method whose body runs `call`.
        def self.made_in(call, in_place)
          name, singleton = call.enclosing ? [call.enclosing, call.singleton] : (call.blocks&.first if call.blocks && in_place.call(call))
          [name, [call.owner, singleton]] if name
        end

        def owners_of(name) = name == :new ? owners.fetch(:initialize, Set[]).to_set { |owner, _| [owner, true] } : owners.fetch(name, Set[])

        def reached(calls, reaching) = calls.select { |call| reaching.call(call, owners_of(call.called)) }
      end
    end
  end
end

module Steep
  module Specializations
    # What a method returns across the whole program: the union of what each of
    # its calls returned, checked for what that call passes.
    #
    #   def self.has_many_like(name)
    #     class_eval "def #{Inflector.singularize(name.to_s)}_ids; []; end"
    #   end
    #
    #   has_many_like :posts         # :post_ids
    #   has_many_like :categories    # :category_ids
    #
    # Only where every call was answered. One left out — a call fixing no
    # value, one whose return was not specialized, one made through a receiver
    # that may be another class — can return anything the declaration allows.
    module CallSiteUnions
      class << self
        # Yields each project method in `keys` that a call in `typing` makes,
        # with what that call returns, or nil where `store` does not say.
        def each_answer(typing, keys, store, factory)
          Collector.each_call_site(typing, every_call: true) do |key, arguments, _node|
            next unless keys.include?(key)

            yield key, arguments && store.call_return_type(key, arguments, factory: factory)
          end
        end

        # What the body of `def_node` answers in place of its own type, where
        # it is checked under its declaration rather than for one call.
        #
        # Keyed by this `def`, not by the declaration it is checked under: an
        # override with no signature of its own shares its parent's.
        def body_answer(constr, def_node)
          store = constr.specializations
          return nil if store.empty? || constr.specialization_arguments(def_node)

          store.memoize(def_node) do
            key = definition_keys(store, constr.source)[def_node]
            key && store.declaration_type(key, factory: constr.checker.factory)
          end
        end

        private

        def definition_keys(store, source)
          store.memoize(source) do
            Collector.definitions(source).each_with_object({}.compare_by_identity) { |(key, node), keys| keys[node] = key }
          end
        end
      end
    end
  end
end

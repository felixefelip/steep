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
      # The arguments every call of a method passes, read where the call is
      # made. A call inside the body of another method is read under each set
      # of arguments THAT method is called with, where all of them are known:
      #
      #   def self.banana_delegate(method) = Writer.generate(self, method)
      #
      #   banana_delegate :human_name   # on Peel
      #   banana_delegate :nick         # on Rind
      #
      # Read once under its declaration, `generate` is passed
      # `(self, (:human_name | :nick))`; read under each call of
      # `banana_delegate`, it is passed `(singleton(Peel), :human_name)` and
      # `(singleton(Rind), :nick)`.
      class Reader
        # `sites`: every call of a method, as `[path, node, arguments]`, read
        # under the declarations (`Collector.each_call_site`, `every_call:`).
        # `check`: the typing of a method's file with its body checked under
        # one set of arguments.
        def initialize(store:, factory:, definitions:, sites:, check:)
          @store = store
          @factory = factory
          @sites = sites
          @check = check
          @arguments = {} #: Hash[String, Array[Arguments]?]
          @definitions_by_path = definitions.each_with_object(Hash.new { |hash, path| hash[path] = [] }) do |(key, (path, def_node)), result|
            result[path] << [key, def_node]
          end
        end

        # The union of what every call of `key` returned, or nil where one is
        # not known.
        def union(key)
          arguments = arguments_of(key) or return nil
          types = arguments.map { |each| @store.call_return_type(key, each, factory: @factory) or return nil }
          AST::Types::Union.build(types: types)
        end

        private

        # nil while `key` is being read: a call reached again through itself is
        # read under the declarations instead. So is a call inside a method
        # nothing in the source calls, which the framework may call by name.
        def arguments_of(key)
          return @arguments[key] if @arguments.key?(key)

          @arguments[key] = nil
          sites = sites_of(key)
          return nil if sites.empty?

          @arguments[key] = sites.flat_map do |path, node, arguments|
            enclosing = enclosing_key(path, node)
            outer = enclosing && arguments_of(enclosing)
            next [arguments || (return nil)] unless outer

            outer.map { |each| Arguments.recorded(node, @check.call(enclosing, each)) || (return nil) }
          end.uniq
        end

        # An `initialize` runs where its class is built, as well as where a
        # `super` reaches it.
        def sites_of(key)
          return @sites.call(key) unless key.end_with?("#initialize")

          @sites.call(key) + @sites.call(Collector.constructor_key(key))
        end

        def enclosing_key(path, node)
          Collector.enclosing(@definitions_by_path[path], node)&.first
        end
      end

      class << self

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

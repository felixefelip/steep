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
        # one set of arguments. `runs`: the keys of the bodies a call node
        # runs in a typing, or nil where that is not known (`Overrides#runs`).
        def initialize(store:, factory:, definitions:, sites:, check:, runs:)
          @store = store
          @factory = factory
          @sites = sites
          @check = check
          @runs = runs
          @arguments = {} #: Hash[String, Array[Arguments]?]
          @namesakes = definitions.keys.group_by { |key| key.rpartition(/[.#]/).drop(1) }
          @definitions_by_path = definitions.each_with_object(Hash.new { |hash, path| hash[path] = [] }) do |(key, (path, def_node)), result|
            result[path] << [key, def_node]
          end
        end

        # The union of what every call of `key` returned, or nil where one is
        # not known.
        def union(key)
          arguments = arguments_of(key) or return nil
          types = arguments.map do |each|
            type = @store.call_return_type(key, each, factory: @factory)
            type && !Specializations.answers_self?(type) ? type : (return nil)
          end
          AST::Types::Union.build(types: types)
        end

        private

        # nil while `key` is being read: a call reached again through itself is
        # read under the declarations instead. So is a call inside a method
        # nothing in the source calls, which the framework may call by name.
        #
        # Under the arguments of the method it is in, a call may run another
        # class's body of the same name than under the declarations, and it
        # counts for the bodies it runs there.
        def arguments_of(key)
          return @arguments[key] if @arguments.key?(key)

          @arguments[key] = nil
          read = namesake_sites(key).flat_map do |path, node, arguments, own|
            enclosing = enclosing_key(path, node)
            outer = enclosing && arguments_of(enclosing)
            next(own ? [arguments || (return nil)] : []) unless outer

            outer.filter_map do |each|
              typing = @check.call(enclosing, each)
              ran = @runs.call(typing, node)
              next unless ran ? ran.include?(key) : own

              Arguments.recorded(node, typing) || (return nil)
            end
          end.uniq
          @arguments[key] = read unless read.empty?
        end

        def namesake_sites(key)
          (@namesakes[key.rpartition(/[.#]/).drop(1)] || [key]).flat_map do |namesake|
            sites_of(namesake).map { |site| [*site, namesake == key] }
          end
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

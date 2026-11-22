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
        # `typings`: each file's typing under the declarations, read for every
        # call of a method in the files `paths` names for it.
        # `check`: the typing of a method's file with its body checked under
        # one set of arguments.
        def initialize(store:, factory:, definitions:, typings:, paths:, overrides:, check:)
          @store = store
          @factory = factory
          @sites = CallSiteUnions.sites(typings, overrides: overrides, paths: paths)
          @check = check
          @runs = ->(typing, node) { Collector.runs_at(typing, node, overrides: overrides) }
          @definitions = definitions
          @arguments = {} #: Hash[String, Array[Arguments]?]
          @selves = {} #: Hash[String, Array[AST::Types::t?]]
          @framed = {} #: Hash[String, bool]
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

        # The `self` every call of `key` runs its body on (`CalleeSelf`), read
        # where `arguments_of` reads the call, or nil where one is not known.
        def selves(key)
          arguments_of(key) or return nil
          selves = @selves.fetch(key)
          selves.uniq unless selves.include?(nil)
        end

        # `selves`, as RBS, where they are not just the class `key` is defined in.
        def foreign_selves(key)
          return nil if constructor?(key)

          selves = selves(key) or return nil
          owner, _, singleton = Specializations.method_key_parts(key)
          written = selves.map { |type| Specializations.rbs_writable(type).to_s }.sort
          written unless written == [singleton ? "singleton(#{owner})" : owner.to_s]
        end

        # Whether the call at `node` in `path` is made inside a method every
        # call of which is read here, each with arguments its body is
        # re-checked under (`specialized`), and made outside any method or
        # inside one that is itself framed, whose re-checks are what read it.
        # That body runs only under those calls, so a call it makes is one of
        # the calls the re-checks read; read under the declarations, it would
        # be a call no run makes.
        def framed?(path, node, &specialized)
          key = enclosing_key(path, node) or return false
          framed_key?(key, &specialized)
        end

        private

        def framed_key?(key, &specialized)
          @framed.fetch(key) do
            @framed[key] = false
            @framed[key] = framed_calls?(key, &specialized)
          end
        end

        def framed_calls?(key, &specialized)
          calls = arguments_of(key) or return false
          calls.all? { |arguments| specialized.call(key, arguments) } &&
            namesake_sites(key).all? { |path, node| (outer = enclosing_key(path, node)).nil? || framed_key?(outer, &specialized) }
        end

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
          selves = [] #: Array[AST::Types::t?]
          read = namesake_sites(key).flat_map do |path, node, arguments, typing, own|
            enclosing = enclosing_key(path, node)
            outer = enclosing && arguments_of(enclosing)
            unless outer
              next [] unless own

              selves << callee_self(typing, node)
              next [arguments || (return nil)]
            end

            outer.filter_map do |each|
              typing = @check.call(enclosing, each)
              ran = @runs.call(typing, node)
              next unless ran ? ran.intersect?(names_of(key)) : own

              selves << callee_self(typing, node)
              Arguments.recorded(node, typing) || (return nil)
            end
          end.uniq
          @selves[key] = selves
          @arguments[key] = read unless read.empty?
        end

        # An `initialize` runs on the instance its call builds, which the call does not name.
        def constructor?(key)
          _, def_node = @definitions[key]
          def_node&.type == :def && def_node.children[0] == :initialize
        end

        def callee_self(typing, node)
          node = typing.explicit_super_of(node: node) || node if node.type == :zsuper
          CalleeSelf.of(typing, node)
        rescue Typing::UnknownNodeError
          nil
        end

        def namesake_sites(key)
          (@namesakes[key.rpartition(/[.#]/).drop(1)] || [key]).flat_map do |namesake|
            sites_of(namesake).map { |site| [*site, namesake == key] }
          end
        end

        # An `initialize` runs where its class is built, as well as where a
        # `super` reaches it.
        def sites_of(key)
          names_of(key).flat_map { |name| @sites.call(name) }
        end

        def names_of(key)
          key.end_with?("#initialize") ? [key, Collector.constructor_key(key)] : [key]
        end

        def enclosing_key(path, node)
          Collector.enclosing(@definitions_by_path[path], node)&.first
        end
      end

      class << self
        # Every call of a method, as `Reader` reads them, in the files `paths`
        # names for it.
        def sites(typings, overrides:, paths:)
          by_path = Hash.new do |hash, path|
            sites = Hash.new { |by_key, key| by_key[key] = [] } #: Hash[String, Array[untyped]]
            Collector.each_call_site(typings[path], overrides: overrides, every_call: true) { |key, arguments, node| sites[key] << [path, node, arguments, typings[path]] }
            hash[path] = sites
          end

          ->(key) { paths.call(key).flat_map { |path| by_path[path].fetch(key, []) } }
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

        # The `self`s every call runs the body of `def_node` on, where it is
        # checked on another one.
        def body_selves(constr, def_node)
          store = constr.specializations
          return nil if store.empty? || constr.specialization_arguments(def_node)

          key = definition_keys(store, constr.source)[def_node] or return nil
          selves = store.selves(key, factory: constr.checker.factory) or return nil
          selves unless selves.include?(constr.self_type)
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

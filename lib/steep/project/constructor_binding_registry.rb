module Steep
  class Project
    # Project-wide index mapping each class's attr-style reader methods to the
    # constructor parameter index their backing ivar is assigned from. Consumed
    # by `TypeConstruction` at `.new` call sites to translate an `initialize`
    # precondition on `self.<reader>...` into an obligation on the matching
    # constructor argument (felixefelip/steep#60).
    #
    # Built and invalidated exactly like `DelegationRegistry`: a full source
    # sweep on first access, rebuilt from scratch on any source change. RBS-only
    # classes have no Ruby body to analyze and are simply absent — `bindings_for`
    # returns nil and the caller falls through.
    class ConstructorBindingRegistry
      # The methods, of any class, a call of which may run a store into a hash
      # memo, by name, and whether `new` may, through an `initialize` that does.
      StoringClosure = Struct.new(:methods, :constructs)

      def self.build(project)
        new.tap { |r| r.build(project) }
      end

      def self.from_paths(paths)
        new.tap do |registry|
          paths.each { |path| registry.ingest(Pathname(path)) }
        end
      end

      def initialize
        @entries = {} #: Hash[String, Hash[Symbol, Integer]]
        @initializers = {} #: Hash[String, Array[TypeInference::ConstructorBindingAnalyzer::Body?]]
        @methods = {} #: Hash[String, Hash[Symbol, Array[TypeInference::ConstructorBindingAnalyzer::Body?]]]
        @singleton_methods = {} #: Hash[String, Hash[Symbol, Array[TypeInference::ConstructorBindingAnalyzer::Body?]]]
        @nodes = [] #: Array[::Parser::AST::Node]
        @class_bodies = Hash.new(0) #: Hash[String, Integer]
        @mixin_bodies = {} #: Hash[String, Array[Array[String]]]
        @declared = Set[] #: Set[String]
        @born_hashes = {} #: Hash[String, Hash[Symbol, Symbol]]
        @uses = nil #: Hash[Symbol, Array[TypeInference::ClassMemoAnalyzer::Use]]?
        @block_calls = {} #: Hash[Symbol, Array[Symbol]]
        @calls = {} #: Hash[Symbol, Array[TypeInference::ClassMemoAnalyzer::Use]]
        @class_body_storing = {} #: Hash[[Symbol, Symbol], Set[Symbol]?]
        @storing_closure = {} #: Hash[[Symbol, Symbol], StoringClosure?]
        @initializing = Set[] #: Set[Symbol]
      end

      # @return self
      def build(project)
        loader = Services::FileLoader.new(base_dir: project.base_dir)
        paths = project.targets.flat_map { |target| loader.each_path_in_target(target).to_a }.uniq
        paths.each { |relative_path| ingest(project.absolute_path(relative_path)) }
        @entries.freeze
        @initializers.freeze
        @methods.freeze
        @singleton_methods.freeze
        index_uses
        @uses.freeze
        @nodes.clear
        self
      end

      # @param class_name [String, #to_s]
      # @return [Hash[Symbol, Integer], nil] all reader→index bindings for the
      #   class, or nil when it has none
      def bindings_for(class_name)
        @entries[class_name.to_s.sub(/\A::/, "")]
      end

      # The ivars `class_name`'s `initialize` binds straight from a positional
      # argument, by that argument's position (felixefelip/steep#205):
      # `{ :@name => 0 }` says `Reflection.new(:posts)` leaves `:posts` in
      # `@name`. Empty unless the project defines exactly one `initialize` for
      # the class. Whether anything writes the ivar afterwards is not this
      # index's question: `ObjectStates` asks the postconditions' `may_write`.
      def ivar_bindings_for(class_name)
        initializers = initializers_for(class_name)
        return {} unless initializers.size == 1

        initializers.first&.bindings || {}
      end

      # Every `initialize` the project defines for `class_name` (a class or a
      # module), as `TypeInference::ConstructorBindingAnalyzer::Body`,
      # nil for one it cannot read. More than one: which runs is load order.
      def initializers_for(class_name)
        @initializers[class_name.to_s.delete_prefix("::")] || []
      end

      # What `class_name#method_name` does to the object it runs on, read off
      # its body (`TypeInference::ConstructorBindingAnalyzer::Body`). Nil
      # unless the project defines the method there exactly once, in a shape
      # that always runs.
      def body_of(class_name, method_name)
        bodies = methods_of(class_name)[method_name.to_sym] or return nil
        bodies.first if bodies.size == 1
      end

      # How many `class`/`module` bodies the project writes for `class_name`
      # that run code (`ConstructorBindingAnalyzer::Scan#class_bodies`).
      def class_bodies(class_name)
        name = class_name.to_s.delete_prefix("::")
        @class_bodies[name] + (@mixin_bodies[name] || []).count { |names| names.none? { |mixed| inert?(mixed) } }
      end

      # The ivars a statement of a body of `class_name` sets to an empty hash,
      # each with how (`ConstructorBindingAnalyzer::Scan#born_hashes`).
      def born_hashes(class_name)
        @born_hashes.fetch(class_name.to_s.delete_prefix("::"), {})
      end

      MIXIN_HOOKS = %i[included extended prepended append_features extend_object prepend_features].freeze

      # A module the project writes whose bodies run nothing, and which defines
      # no hook: mixing it in runs no code of the project's.
      def inert?(name)
        @declared.include?(name) && @class_bodies[name].zero? && !@mixin_bodies.key?(name) &&
          MIXIN_HOOKS.none? { |hook| defines?(name, hook, singleton: true) }
      end

      # Every body the project may define for `class_name#method_name`s,
      # nil for one this cannot read.
      def method_bodies(class_name)
        methods_of(class_name)
      end

      # Whether any class of the project defines one of `names`.
      def defines_any?(names)
        @defined_names ||= @methods.each_value.flat_map(&:keys).to_set
        names.any? { |name| @defined_names.include?(name) }
      end

      def singleton_method_bodies(class_name)
        @singleton_methods[class_name.to_s.delete_prefix("::")] || {}
      end

      # `body_of` for a method of the class object itself.
      def singleton_body_of(class_name, method_name)
        bodies = (@singleton_methods[class_name.to_s.delete_prefix("::")] || {})[method_name.to_sym] or return nil
        bodies.first if bodies.size == 1
      end

      # Every place the project names `name`, one of its class memos
      # (`Body#memo`) or a memo's ivar, by spelling
      # (`TypeInference::ClassMemoAnalyzer`).
      def uses_of(name)
        index_uses unless @uses
        @uses.fetch(name.to_sym, [])
      end

      # Every name `uses_of` answers for, and every one `calls_of` does.
      def used_names
        index_uses unless @uses
        @uses.keys.to_set | keyed_memo_names
      end

      # Where a hash keeps a keyed memo (`Body#keyed_memo`), what builds its
      # objects, and its class's methods, whose callers decide when what the
      # memo stores may change.
      def keyed_memo_names
        return @keyed_memo_names if @keyed_memo_names

        keyed = @methods.select { |_, methods| methods.each_value.any? { |bodies| bodies.any? { |body| body&.keyed_memo } } }
        @keyed_memo_names = keyed.empty? ? Set[] : keyed.each_value.flat_map(&:keys).to_set | %i[new allocate]
      end

      # The calls that may run a store into the hash `memo` keeps in `ivar`
      # (`StoringClosure`); nil where a store may run from code no method name
      # stands for.
      def storing_closure(memo, ivar)
        index_uses unless @uses
        @storing_closure[[memo.to_sym, ivar.to_sym]]
      end

      # Every call the project makes of `name`, one of `keyed_memo_names`
      # (`TypeInference::ClassMemoAnalyzer.calls`).
      def calls_of(name)
        index_uses unless @uses
        @calls.fetch(name.to_sym, [])
      end

      # Whether `name` runs only while an object is initialized: every call
      # the project makes of it is made on `self` by an `initialize`, or by
      # another method that does.
      def initializing?(name)
        index_uses unless @uses
        @initializing.include?(name.to_sym)
      end

      # The class methods that store into the hash `memo` keeps in `ivar`,
      # where every store is made by a class body on its own class; nil
      # otherwise.
      def class_body_storing(memo, ivar)
        index_uses unless @uses
        @class_body_storing[[memo.to_sym, ivar.to_sym]]
      end

      # Whether every call of `method_name`, a method that yields a memo, hands
      # it a block a `yield` checks in place, or none
      # (`ClassMemoAnalyzer.block_calls`).
      def replayed_everywhere?(method_name)
        index_uses unless @uses
        @block_calls.fetch(method_name.to_sym, []).all? { |kind| kind != :other }
      end

      # Whether the project may define `method_name` in `class_name` at all, on
      # its instances or, with `singleton`, on the class object.
      def defines?(class_name, method_name, singleton: false)
        methods = singleton ? @singleton_methods[class_name.to_s.delete_prefix("::")] || {} : methods_of(class_name)
        methods.key?(method_name.to_sym)
      end

      def empty?
        @entries.empty?
      end

      def to_h
        @entries
      end

      def ingest(absolute_path)
        ingest_source(absolute_path.read, path_name: absolute_path.to_s) if absolute_path.file? && ruby_source?(absolute_path)
      end

      def ingest_source(content, path_name:)
        node = parse(content, path_name)
        return unless node
        scan = TypeInference::ConstructorBindingAnalyzer.scan(node)
        scan.readers.each { |class_name, readers| (@entries[class_name] ||= {}).merge!(readers) }
        scan.initializers.each { |class_name, initializers| (@initializers[class_name] ||= []).concat(initializers) }
        scan.class_bodies.each { |class_name, count| @class_bodies[class_name] += count }
        scan.mixin_bodies.each { |class_name, bodies| (@mixin_bodies[class_name] ||= []).concat(bodies) }
        @declared.merge(scan.declared)
        scan.born_hashes.each { |class_name, ivars| (@born_hashes[class_name] ||= {}).merge!(ivars, &TypeInference::ConstructorBindingAnalyzer::JOIN_BIRTHS) }
        merge_bodies(@methods, scan.methods)
        merge_bodies(@singleton_methods, scan.singleton_methods)
        @nodes << node
        @uses = nil
        @defined_names = nil
        @keyed_memo_names = nil
      rescue StandardError, ::Parser::SyntaxError => e
        Steep.logger.warn { "[constructor_binding_registry] failed to ingest #{path_name}: #{e.message}" }
      end

      private

      # A method a use forwards (`ClassMemoAnalyzer::Use#forwarded_by`) is
      # used where it is called.
      def uses_by_name(names)
        found = {} #: Hash[Symbol, Array[TypeInference::ClassMemoAnalyzer::Use]]
        indexed = Set[] #: Set[Symbol]
        until names.empty?
          indexed.merge(names)
          @nodes.each do |node|
            TypeInference::ClassMemoAnalyzer.uses(node, names: names).each { |name, uses| (found[name] ||= []).concat(uses) }
          end
          names = found.each_value.flat_map { |uses| uses.flat_map { |use| use.enum_for(:each_forwarder).to_a } }.to_set - indexed
        end
        found
      end

      def merge_bodies(index, scanned)
        scanned.each do |class_name, methods|
          entry = (index[class_name] ||= {})
          methods.each { |name, bodies| (entry[name] ||= []).concat(bodies) }
        end
      end

      # Read only once every source is in, since a memo may be used in a
      # source read before the one that defines it.
      def index_uses
        names = Set[] #: Set[Symbol]
        @singleton_methods.each_value do |methods|
          methods.each { |name, bodies| bodies.each { |body| names << name << body.memo[0] if body&.memo } }
        end
        hashes = hash_memos
        hashes.each { |name, ivar| names << name << ivar }
        @methods.each { |class_name, methods| names.merge(accumulated_names(methods)).merge(bound_names(@initializers.fetch(class_name, []), methods)) }
        names.merge(keyed_memo_names)
        @uses = uses_by_name(names)
        calls_named(keyed_memo_names)
        @storing_closure = hashes.to_h { |memo, ivar| [[memo, ivar], closure_of_stores(memo, ivar)] }
        @class_body_storing = @storing_closure.transform_values { |closure| class_body_storing_methods(closure) }
        @initializing = initializing_methods
        yielders = @uses.each_value.flat_map { |uses| uses.select { |use| use.kind == :yielded }.map(&:called) }.to_set
        @block_calls = {}
        @nodes.each do |node|
          TypeInference::ClassMemoAnalyzer.block_calls(node, names: yielders).each { |name, kinds| (@block_calls[name] ||= []).concat(kinds) }
        end
      end

      def initializing_methods
        reached = Set[] #: Set[Symbol]
        sends = @initializers.each_value.flat_map { |bodies| bodies.flat_map { |body| body&.self_sends.to_a } }
        until sends.empty?
          names = sends.to_set - reached - [:initialize]
          reached.merge(names)
          sends = @methods.each_value.flat_map { |methods| names.flat_map { |name| methods.fetch(name, []).flat_map { |body| body&.self_sends.to_a } } }
        end
        calls = reached.to_h { |name| [name, calls_named([name])] }
        loop do
          kept = reached.select do |name|
            calls[name].all? { |call| call.on_self && !call.singleton && (call.enclosing == :initialize || reached.include?(call.enclosing)) }
          end.to_set
          return kept if kept == reached

          reached = kept
        end
      end

      # `[memo, ivar]` for each hash a class keeps: what a memo of `{}` holds
      # (`Body#memoized_hash`), or what an ivar a class body sets to `{}`
      # holds, reached by the ivar itself.
      def hash_memos
        readers = @singleton_methods.each_value.flat_map do |methods|
          methods.flat_map { |name, bodies| bodies.filter_map { |body| [name, body.memoized_hash] if body&.memoized_hash } }
        end
        readers.to_set | @born_hashes.each_value.flat_map { |ivars| ivars.each_key.map { |ivar| [ivar, ivar] } }
      end

      # Every call the project makes of one of `names`, each name looked for
      # in the sources once.
      def calls_named(names)
        unscanned = names.to_set - @calls.keys
        unless unscanned.empty?
          unscanned.each { |name| @calls[name] = [] }
          @nodes.each do |node|
            TypeInference::ClassMemoAnalyzer.calls(node, names: unscanned).each { |name, calls| @calls[name].concat(calls) }
          end
        end
        names.flat_map { |name| @calls[name] }
      end

      # Each store into the hash is a use of the memo or its ivar on `self`
      # (`ClassMemoAnalyzer::Use`).
      def stores_into(memo, ivar)
        [memo, ivar].flat_map { |name| @uses.fetch(name, []) }.select { |use| HASH_STORES.include?(use.called) }
      end

      def closure_of_stores(memo, ivar)
        stores = stores_into(memo, ivar)
        return if stores.any? { |use| use.kind != :statement && !use.within }

        storing = stores.filter_map(&:within).to_set
        loop do
          constructs = storing.include?(:initialize)
          calls = calls_named(constructs ? storing | [:new] : storing)
          return if calls.any? { |call| call.kind == :escape || !(call.in_class_body || call.enclosing) }

          grown = calls.filter_map(&:enclosing).to_set - storing
          return StoringClosure.new(storing - [:initialize], constructs) if grown.empty?

          storing |= grown
        end
      end

      # The closure, where each call of its methods is a statement of a class
      # body on its own class or is made by one of them on `self`.
      def class_body_storing_methods(closure)
        return unless closure && !closure.constructs

        closure.methods if calls_named(closure.methods).all? { |call| call.kind == :statement || closure.methods.include?(call.within) }
      end

      HASH_STORES = HashMutation::STORES.to_set { |key| key.split("#").last.to_sym }.freeze

      # The ivars a class's methods start as an empty array, and the readers
      # that hand them out.
      def accumulated_names(methods)
        ivars = methods.values.flatten.compact.flat_map { |body| body.empties.to_a }.to_set
        ivars | readers(methods, ivars)
      end

      # The readers of the ivars an `initialize` binds from its arguments,
      # whose uses `HashMutation.read_only?` follows.
      def bound_names(initializers, methods)
        readers(methods, initializers.compact.flat_map { |body| body.bindings.keys }.to_set)
      end

      def readers(methods, ivars)
        methods.select { |_, found| found.any? { |body| body && ivars.include?(body.returns) } }.keys
      end

      def methods_of(class_name)
        @methods[class_name.to_s.delete_prefix("::")] || {}
      end

      def ruby_source?(path)
        ext = path.extname
        ext == ".rb" || ext == ".rake"
      end

      def parse(content, path_name)
        buffer = ::Parser::Source::Buffer.new(path_name)
        buffer.source = content
        parser = ::Parser::Ruby33.new
        parser.diagnostics.all_errors_are_fatal = false
        parser.diagnostics.ignore_warnings = true
        parser.parse(buffer)
      rescue ::Parser::SyntaxError
        nil
      end
    end
  end
end

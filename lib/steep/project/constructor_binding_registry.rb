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
        start_method_tables
        @nodes = [] #: Array[::Parser::AST::Node]
        @class_bodies = Hash.new(0) #: Hash[String, Integer]
        @mixin_bodies = {} #: Hash[String, Array[Array[String]]]
        @declared = Set[] #: Set[String]
        @born_hashes = {} #: Hash[String, Hash[Symbol, Symbol]]
        @born_objects = {} #: Hash[String, Hash[Symbol, Symbol]]
        @uses = nil #: Hash[Symbol, Array[TypeInference::ClassMemoAnalyzer::Use]]?
        @block_calls = {} #: Hash[Symbol, Array[Symbol]]
        @calls = {} #: Hash[Symbol, Array[TypeInference::ClassMemoAnalyzer::Use]]
        @hash_memos = Set[] #: Set[[Symbol, Symbol]]
        @forwarded_stores = Set[] #: Set[Symbol]
        @initializing = Set[] #: Set[Symbol]
        @constant_literals = {} #: Hash[Symbol, [::Parser::AST::Node, String]]
        @constant_writes = Hash.new(0) #: Hash[Symbol, Integer]
        @postconditions = nil #: (^() -> Postconditions::Store)?
      end

      # @return self
      def build(project)
        @postconditions = -> { project.postconditions }
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
        name = class_name.to_s.delete_prefix("::")
        unreached?("#{name}#initialize") ? [] : @initializers[name] || []
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

      # The ivars a statement of a body of `class_name` sets to `Klass.new`
      # handed nothing, each with how.
      def born_objects(class_name)
        @born_objects.fetch(class_name.to_s.delete_prefix("::"), {})
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

      # Each body `method_bodies` lists, with those defined in a branch of the
      # class body read as written: what a body may do where it runs, whether
      # or not it is defined. A method also left with a body this cannot read
      # keeps it.
      def possible_bodies(class_name)
        conditional = @conditional_methods.fetch(class_name.to_s.delete_prefix("::"), {})
        method_bodies(class_name).to_h do |method_name, bodies|
          read = conditional.fetch(method_name, [])
          [method_name, bodies.count(&:nil?) == read.size ? bodies.compact + read : bodies]
        end
      end

      # The method `class_name#method_name` copies where it is an alias its
      # class body makes, by the name it was made from.
      def aliased(class_name, method_name)
        @aliases.dig(class_name.to_s.delete_prefix("::"), method_name)
      end

      # `[value node, qualified name]` for a constant the project writes once,
      # as a scalar (`Constants.scalars`), by its bare name: the checker
      # compares the qualified name with the constant a read resolved to.
      def constant_literal(name)
        @constant_literals[name] if @constant_writes[name] == 1
      end

      # Whether any class of the project defines one of `names`.
      def defines_any?(names)
        @defined_names ||= @methods.each_value.flat_map(&:keys).to_set
        names.any? { |name| @defined_names.include?(name) }
      end

      def singleton_method_bodies(class_name)
        reached(@singleton_methods, class_name, ".")
      end

      # `body_of` for a method of the class object itself.
      def singleton_body_of(class_name, method_name)
        bodies = singleton_method_bodies(class_name)[method_name.to_sym] or return nil
        bodies.first if bodies.size == 1
      end

      # Every place the project names `name`, one of its class memos
      # (`Body#memo`) or a memo's ivar, by spelling
      # (`TypeInference::ClassMemoAnalyzer`).
      def uses_of(name)
        index_uses unless @uses
        @uses.fetch(name.to_sym, [])
      end

      # `uses_of`, for a reader it does not index too, and what forwards one:
      # indexed apart, so what `uses_of` answers, and how it records a use of
      # another name made through this one, stay as they were.
      def every_use_of(name)
        index_uses unless @uses
        @uses[name.to_sym] || @reader_uses.fetch(name.to_sym, [])
      end

      # Every name `uses_of` answers for, and every one `calls_of` does.
      def used_names
        index_uses unless @uses
        @uses.keys.to_set | @calls.keys
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
      # stands for. `reaching` says whether a call of a method of the closure
      # may run that method.
      def storing_closure(memo, ivar, reaching:)
        index_uses unless @uses
        key = [memo.to_sym, ivar.to_sym]
        closure_of_stores(*key, reaching: reaching) if @hash_memos.include?(key)
      end

      # `storing_closure` for the object a class body keeps in `ivar`, where
      # it forwards to a hash it keeps (`ObjectStates::ForwardedHash`): a call
      # of any method of the project's that stores into an ivar's hash may
      # be one of its stores.
      def forwarded_storing_closure(ivar, reaching:)
        index_uses unless @uses
        ivar = ivar.to_sym
        closure_of_stores(ivar, ivar, @forwarded_stores, reaching: reaching) if @born_objects.each_value.any? { |ivars| ivars.key?(ivar) }
      end

      # The classes that define `method_name`, on their instances or, with
      # `singleton`, on the class object, as `[class_name, singleton]`.
      def owners_of(method_name)
        name = method_name.to_sym
        [[@methods, false], [@singleton_methods, true]].flat_map do |table, singleton|
          table.filter_map { |class_name, methods| [class_name, singleton] if methods.key?(name) }
        end
      end

      # Every call the project makes of `name`, one of `keyed_memo_names`
      # (`TypeInference::ClassMemoAnalyzer.calls`).
      def calls_of(name)
        index_uses unless @uses
        @calls.fetch(name.to_sym, [])
      end

      # What runs only on an object being built: `new` runs `initialize`, and
      # `dup` and `clone` run the copy hooks on the copy they made.
      INITIALIZERS = %i[initialize initialize_copy initialize_dup initialize_clone].freeze

      # Whether `name` runs only while an object is initialized: every call
      # the project makes of it is made on `self` by one of `INITIALIZERS`, or
      # by another method that does.
      def initializing?(name)
        index_uses unless @uses
        @initializing.include?(name.to_sym)
      end

      # The class methods that store into the hash `memo` keeps in `ivar`,
      # where every store is made by a class body on its own class; nil
      # otherwise.
      def class_body_storing(memo, ivar, reaching:)
        class_body_storing_methods(storing_closure(memo, ivar, reaching: reaching), reaching)
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
        methods = singleton ? singleton_method_bodies(class_name) : methods_of(class_name)
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
        [[@born_hashes, scan.born_hashes], [@born_objects, scan.born_objects]].each do |index, scanned|
          scanned.each { |class_name, ivars| (index[class_name] ||= {}).merge!(ivars, &TypeInference::ConstructorBindingAnalyzer::JOIN_BIRTHS) }
        end
        ingest_methods(scan)
        ingest_constants(node, content)
        @nodes << node
        @uses = nil
        @defs_by_name = nil
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
          found.each_value { |uses| hand_on(uses) }
          names = found.each_value.flat_map { |uses| uses.flat_map { |use| use.enum_for(:each_forwarder).to_a } }.to_set - indexed
        end
        found
      end

      # Fills each `handed_to` among `uses` with what every body of a method of
      # that name does with that parameter. One the program defines no body
      # for, or whose parameters do not say which one it is, stays the escape.
      def hand_on(uses, handing = Set[])
        uses.each do |use|
          hand_on(use.value, handing) if use.value
          next unless use.handed_to && use.handed.nil? && !use.frozen?

          use.handed = handed_uses(*use.handed_to, handing)
        end
      end

      def handed_uses(method_name, index, handing)
        return [] if handing.include?([method_name, index])

        defs = defs_named(method_name)
        return if defs.empty?

        defs.flat_map do |def_node|
          uses = TypeInference::ClassMemoAnalyzer.parameter_uses(def_node, index) or return
          hand_on(uses, handing | [[method_name, index]])
          uses
        end
      end

      def defs_named(method_name)
        @defs_by_name ||= @nodes.each_with_object(Hash.new { |by_name, name| by_name[name] = [] }) { |node, by_name| collect_defs(node, by_name) }
        @defs_by_name.fetch(method_name, [])
      end

      def collect_defs(node, by_name)
        return unless node.is_a?(::Parser::AST::Node)

        by_name[node.children[0]] << node if node.type == :def
        by_name[node.children[1]] << node if node.type == :defs
        node.children.each { |child| collect_defs(child, by_name) }
      end

      # The tables `ingest_methods` merges each scan's methods into.
      def start_method_tables
        @methods = {} #: Hash[String, Hash[Symbol, Array[TypeInference::ConstructorBindingAnalyzer::Body?]]]
        @singleton_methods = {} #: Hash[String, Hash[Symbol, Array[TypeInference::ConstructorBindingAnalyzer::Body?]]]
        @conditional_methods = {} #: Hash[String, Hash[Symbol, Array[TypeInference::ConstructorBindingAnalyzer::Body?]]]
        @aliases = {} #: Hash[String, Hash[Symbol, Symbol]]
      end

      def ingest_methods(scan)
        merge_bodies(@methods, scan.methods)
        merge_bodies(@singleton_methods, scan.singleton_methods)
        merge_bodies(@conditional_methods, scan.conditional_methods)
        scan.aliases.each { |class_name, aliases| (@aliases[class_name] ||= {}).merge!(aliases) }
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
        @born_objects.each_value { |ivars| names.merge(ivars.keys) }
        @methods.each { |class_name, methods| names.merge(accumulated_names(methods)).merge(bound_names(@initializers.fetch(class_name, []), methods)) }
        names.merge(keyed_memo_names)
        @uses = uses_by_name(names)
        @reader_uses = uses_by_name(reader_names - names)
        calls_named(keyed_memo_names)
        @hash_memos = hashes.to_set
        @forwarded_stores = forwarded_stores
        scan_closures(hashes)
        @initializing = initializing_methods
        index_block_calls
      end

      def index_block_calls
        yielders = @uses.each_value.flat_map { |uses| uses.select { |use| use.kind == :yielded }.map(&:called) }.to_set
        @block_calls = {}
        @nodes.each do |node|
          TypeInference::ClassMemoAnalyzer.block_calls(node, names: yielders).each { |name, kinds| (@block_calls[name] ||= []).concat(kinds) }
        end
      end

      # Every method a class body defines as a reader of an ivar (`Body#returns`).
      def reader_names
        @methods.each_value.flat_map { |methods| methods.select { |_, bodies| bodies.any? { |body| body&.returns } }.keys }.to_set
      end

      def scan_closures(hashes)
        hashes.each { |memo, ivar| closure_of_stores(memo, ivar, reaching: EVERY_CALL) }
        @born_objects.each_value.flat_map(&:keys).uniq.each { |ivar| closure_of_stores(ivar, ivar, @forwarded_stores, reaching: EVERY_CALL) }
      end

      def forwarded_stores
        HASH_STORES | @methods.each_value.flat_map { |methods| methods.filter_map { |name, bodies| name if bodies.any? { |body| body&.stores_element || body&.block_super } } }
      end

      def initializing_methods
        reached = Set[] #: Set[Symbol]
        copies = @methods.each_value.flat_map { |methods| INITIALIZERS.flat_map { |name| methods.fetch(name, []) } }
        sends = (@initializers.values.flatten + copies).flat_map { |body| body&.self_sends.to_a }
        until sends.empty?
          names = sends.to_set - reached - INITIALIZERS
          reached.merge(names)
          sends = @methods.each_value.flat_map { |methods| names.flat_map { |name| methods.fetch(name, []).flat_map { |body| body&.self_sends.to_a } } }
        end
        calls = reached.to_h { |name| [name, calls_named([name])] }
        loop do
          kept = reached.select do |name|
            calls[name].all? { |call| call.on_self && !call.singleton && (INITIALIZERS.include?(call.enclosing) || reached.include?(call.enclosing)) }
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
      def stores_into(memo, ivar, names)
        [memo, ivar].flat_map { |name| @uses.fetch(name, []) }.select { |use| names.include?(use.called) }
      end

      EVERY_CALL = ->(_call) { true }

      # Grows past a call that escapes, so that `build` scans every name a
      # closure `reaching` fewer calls may ask for: no node is left after it.
      def closure_of_stores(memo, ivar, names = HASH_STORES, reaching:)
        stores = stores_into(memo, ivar, names)
        return if stores.any? { |use| use.kind != :statement && !use.within }

        storing = stores.filter_map(&:within).to_set
        escaped = false
        loop do
          constructs = storing.include?(:initialize)
          calls = calls_named(constructs ? storing | [:new] : storing).select(&reaching)
          escaped ||= calls.any? { |call| call.kind == :escape || !(call.in_class_body || call.enclosing) }

          grown = calls.filter_map(&:enclosing).to_set - storing
          return (StoringClosure.new(storing - [:initialize], constructs) unless escaped) if grown.empty?

          storing |= grown
        end
      end

      # The closure, where each call of its methods is a statement of a class
      # body on its own class or is made by one of them on `self`.
      def class_body_storing_methods(closure, reaching)
        return unless closure && !closure.constructs

        closure.methods if calls_named(closure.methods).select(&reaching).all? { |call| call.kind == :statement || closure.methods.include?(call.within) }
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
        reached(@methods, class_name, "#")
      end

      # The methods `table` holds for `class_name`, but those it defines only
      # in a branch its class body never takes
      # (`Postconditions::UnreachedDefinitions`).
      def reached(table, class_name, separator)
        name = class_name.to_s.delete_prefix("::")
        methods = table[name] || {}
        return methods if unreached_definitions.empty?

        methods.reject { |method_name, _| unreached?("#{name}#{separator}#{method_name}") }
      end

      public

      # Whether `key` (`"Owner#method"`) is defined only in a branch its
      # class body never takes.
      def unreached?(key) = unreached_definitions.include?(key)

      # Whether `owner` defines `method_name` only in a branch its class body
      # may or may not take, so the body an ancestor defines may run instead.
      def conditional?(owner, method_name, singleton: false)
        @postconditions&.call&.conditional_definitions&.include?("#{owner.to_s.delete_prefix("::")}#{singleton ? "." : "#"}#{method_name}") || false
      end

      private

      def unreached_definitions = @postconditions&.call&.unreached_definitions || Set[]

      def ingest_constants(node, content)
        scalars, written = Constants.scalars(node, frozen_strings: frozen_strings?(content))
        @constant_literals.merge!(scalars)
        written.each { |name| @constant_writes[name] += 1 }
      end

      def frozen_strings?(content)
        content.each_line.take_while { |line| line.start_with?("#") || line.strip.empty? }.any? { |line| line.match?(/frozen_string_literal:\s*true/i) }
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

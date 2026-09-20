module Steep
  class Project
    # Conservative project-wide record of Ruby source that can replace one of
    # LiteralIntrinsics' core implementations. RBS method declarations identify
    # the owner and name, but a Ruby reopen has the same owner and name; this
    # source index supplies the missing implementation provenance.
    class LiteralMethodRegistry
      # Every owner a table names, its own entries and the methods they lean
      # on: a reopen is only watched for a class on this list, so a key whose
      # owner is missing is a key nothing can block — including when a parse
      # failure taints everything.
      #
      # `Object`, `Module`, `Class`, `Method` and `UnboundMethod` are here for
      # the reflection table, whose keys are declared on them: an opaque
      # mutation of one of those has to block its entries the way one of `Array`
      # blocks `join`. A reflection redefined anywhere ELSE is recorded too, by
      # name rather than by owner — its receiver is any class the project has,
      # which is not something a list can hold. See `block_method`.
      CORE_CLASSES = Set[
        "String", "Integer", "Symbol", "Array", "Enumerable", "Set", "Kernel",
        "Object", "Module", "Class", "Method", "UnboundMethod"
      ]

      # Both folds are keyed the same way and blocked the same way, so one
      # registry watches both tables.
      TABLES = [LiteralIntrinsics, ReflectionIntrinsics].freeze
      # Only `prepend` shadows an entry by LOOKUP. A module inserted by `include`
      # sits below the class in the chain, and every method in the table is one
      # the core class defines itself, so the class's own always wins:
      #
      #   module M; def join(*) = "hijacked"; end
      #   Array.include M  #=> [1, 2].join(",") == "1,2"
      #   Array.prepend M  #=> [1, 2].join(",") == "hijacked"
      #
      # `extend` reaches the singleton, and the table holds no singleton method.
      LOOKUP_MUTATORS = Set[:prepend]

      # `include` and `extend` still RUN code — `append_features`, `included`,
      # `extend_object`, `extended` — and a hook is free to redefine anything:
      #
      #   module Sneaky
      #     def self.append_features(base)
      #       base.class_eval { def join(*) = "hijacked" }
      #       super
      #     end
      #   end
      #   Array.include Sneaky  #=> [1, 2].join(",") == "hijacked"
      #
      # So they are held until the module is known: one this index has read and
      # which defines no hook (and mixes in nothing further, which would take
      # the question somewhere this cannot follow) is inert and taints nothing.
      # Anything else — a module from a gem, a dynamic argument, a hook — taints
      # as before. That keeps the ordinary `Array.include Conversions` folding
      # without taking the checker's word for a module it has never read.
      HOOK_MUTATORS = Set[:include, :extend]
      MIXIN_HOOKS = Set[:append_features, :included, :extend_object, :extended, :prepend_features, :prepended]
      EVAL_METHODS = Set[:class_eval, :class_exec, :module_eval, :module_exec]
      METHOD_MUTATORS = Set[:define_method, :alias_method, :remove_method, :undef_method]
      SEND_METHODS = Set[:send, :public_send, :__send__]

      def self.build(project)
        new.tap { |registry| registry.build(project) }
      end

      def self.from_paths(paths)
        new.tap do |registry|
          paths.each do |path|
            pathname = Pathname(path)
            registry.ingest(pathname) if pathname.file? && pathname.extname != ".erb"
          end
        end
      end

      def initialize
        # Whether the body being walked is a `class << self`, where instance
        # syntax writes singleton methods.
        @singleton_side = false
        @blocked = Set[] #: Set[String]
        # Reflections whose owner could not be read at all, blocked by name
        # rather than by key.
        @blocked_names = Set[] #: Set[Symbol]
        @mixins = [] #: Array[[String, String?]]
        @modules = Set[] #: Set[String]
        @opaque_modules = Set[] #: Set[String]
      end

      def initialize_copy(original)
        super
        @blocked = original.to_set
        @blocked_names = original.blocked_names
        @mixins = []
        @modules = Set[]
        @opaque_modules = Set[]
      end

      def build(project)
        loader = Services::FileLoader.new(base_dir: project.base_dir)
        project.targets.each do |target|
          loader.each_path_in_target(target) do |relative_path|
            next unless source_path?(target, relative_path)
            next unless ruby_source_path?(relative_path)

            absolute = project.absolute_path(relative_path)
            ingest(absolute) if absolute.file?
          end
        end
        self
      end

      def blocked?(method_name)
        resolve_mixins
        @blocked.include?(normalize(method_name))
      end

      # A method name that cannot be keyed to an owner: blocked wherever it is
      # dispatched, which is what an unreadable receiver leaves.
      def name_blocked?(method_name)
        @blocked_names.include?(method_name.to_sym)
      end

      def blocked_names
        @blocked_names.dup
      end

      def empty?
        resolve_mixins
        @blocked.empty? && @blocked_names.empty?
      end

      def to_set
        resolve_mixins
        @blocked.dup
      end

      def ingest(path)
        ingest_source(path.read, path_name: path.to_s)
      rescue StandardError, ::Parser::SyntaxError => exn
        Steep.logger.warn { "[literal_method_registry] failed to ingest #{path}: #{exn.message}" }
        taint_all
        self
      end

      def ingest_source(content, path_name: "(source)")
        node = parse(content, path_name)
        scan(node, []) if node
        self
      rescue StandardError, ::Parser::SyntaxError => exn
        Steep.logger.warn { "[literal_method_registry] failed to ingest #{path_name}: #{exn.message}" }
        taint_all
        self
      end

      private

      def source_path?(target, path)
        target.source_pattern =~ path ||
          target.inline_source_pattern =~ path ||
          target.groups.any? do |group|
            group.source_pattern =~ path || group.inline_source_pattern =~ path
          end
      end

      # Inline templates are checked by Steep after their framework-specific
      # translation to Ruby. Their source text is not Ruby and feeding it to
      # Parser would conservatively taint every intrinsic in the project.
      def ruby_source_path?(path)
        Pathname(path).extname != ".erb"
      end

      def normalize(method_name)
        string = method_name.to_s
        string.start_with?("::") ? string : "::#{string}"
      end

      def block_method(owner, method_name, singleton: false)
        return unless method_name

        key = "::#{owner}#{singleton ? "." : "#"}#{method_name}"

        # A reflection is shadowed by the RECEIVER's class, and a receiver is
        # any class the project writes — so these are recorded whoever the owner
        # is, and on the side they were written on. The literal table's keys
        # stay confined to the core list below: its receivers are literals, and
        # nothing else can hold one.
        if ReflectionIntrinsics.dispatched_names.include?(method_name.to_sym)
          @blocked << key unless owner.empty?
          return
        end

        return if singleton
        return unless CORE_CLASSES.include?(owner)

        @blocked << key if TABLES.any? { |table| table.watched_keys.include?(key) }
      end

      # The class `def <receiver>.name` writes to: the enclosing one for `self`,
      # the constant itself for a constant, and nil for anything else — an
      # expression, a local, a `self` at the top level where there is no class
      # to name.
      def defs_owner(receiver, nesting, forced_owner)
        case receiver&.type
        when :self
          owner = forced_owner || nesting.join("::")
          owner unless owner.empty?
        when :const
          name, absolute = const_name(receiver)
          if name
            absolute ? name : [*nesting, name].join("::")
          end
        end
      end

      # A reflection whose OWNER cannot be read stops the fold for that name
      # everywhere. There is no class to record it against, and the one it
      # lands on is one a call site may well be holding.
      def block_method_everywhere(method_name)
        return unless method_name
        return unless ReflectionIntrinsics.dispatched_names.include?(method_name.to_sym)

        @blocked_names << method_name.to_sym
      end

      # Every key a reflection could be dispatched under for one owner, both
      # sides. What an opaque mutation of that class blocks: the names are
      # known, the method it writes is not.
      def reflection_keys(owner)
        return [] if owner.empty?

        ReflectionIntrinsics.dispatched_names.flat_map do |name|
          ["::#{owner}##{name}", "::#{owner}.#{name}"]
        end
      end

      def note_hook(owner, method_name)
        @opaque_modules << owner if method_name && MIXIN_HOOKS.include?(method_name.to_sym)
      end

      # What makes a module unreadable, and so unsafe to mix into a core class:
      # it mixes something further in (the question moves somewhere this cannot
      # follow), it builds a method whose NAME this cannot read, or it builds
      # one of the hooks by hand. `class << self; alias included install; end`
      # and `define_method(name_from_a_variable)` both land here.
      def note_opaque_module(owner, method_name, arguments, target)
        mixes_in = LOOKUP_MUTATORS.include?(method_name) || HOOK_MUTATORS.include?(method_name)
        return @opaque_modules << owner if mixes_in && !target

        builds = METHOD_MUTATORS.include?(method_name) || EVAL_METHODS.include?(method_name)
        return unless builds

        name = literal_method_name(arguments.first)
        @opaque_modules << owner if name.nil? || MIXIN_HOOKS.include?(name.to_sym)
      end

      # `alias` writes bare method names, which the parser gives as `:sym` nodes
      # without the quoting `literal_method_name` expects everywhere else.
      def literal_alias_name(node)
        return nil unless node.is_a?(::Parser::AST::Node)

        node.children[0] if node.type == :sym
      end

      # `include`/`extend` taints unless EVERY module it names is one this index
      # read and found inert. Deferred to the first query, and the names are
      # resolved here rather than at the scan: a module may be defined in a file
      # ingested after the mixin site, and deciding earlier makes the answer
      # depend on ingestion order.
      def resolve_mixins
        return if @mixins.empty?

        pending = @mixins
        @mixins = []
        pending.each do |target, references, nesting|
          inert = references.any? && references.all? { |reference| inert_mixin?(reference, nesting) }
          taint(target) unless inert
        end
      end

      # Whether one named module is known to be harmless. A relative constant is
      # matched against the lexical scopes Ruby would search; more than one
      # match is a question this cannot settle, so it counts as unknown — as
      # does a name never read, and anything that is not a plain constant.
      def inert_mixin?(reference, nesting)
        name, absolute = reference
        return false unless name

        candidates =
          if absolute
            [name]
          else
            nesting.size.downto(0).map { |depth| [*nesting.take(depth), name].join("::") }
          end

        found = candidates.uniq.select { |candidate| @modules.include?(candidate) }
        found.size == 1 && !@opaque_modules.include?(found.first)
      end

      def taint(owner)
        return if owner.nil?
        # A class this cannot read the methods of cannot be reflected on either,
        # whether or not it is one of the core classes.
        @blocked.merge(reflection_keys(owner))
        return unless CORE_CLASSES.include?(owner)

        TABLES.each { |table| @blocked.merge(table.method_keys_for(owner)) }
      end

      def taint_all
        CORE_CLASSES.each { |owner| taint(owner) }
      end

      def scan_side(singleton)
        previous = @singleton_side
        @singleton_side = singleton
        yield
      ensure
        @singleton_side = previous
      end

      def scan(node, nesting, forced_owner = nil)
        return unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :class, :module
          name, absolute = const_name(node.children[0])
          owner = absolute ? name : [*nesting, name].compact.join("::")
          body = node.type == :class ? node.children[2] : node.children[1]
          @modules << owner
          scan_side(false) { scan(body, owner.split("::"), nil) }
        when :def
          owner = forced_owner || nesting.join("::")
          block_method(owner, node.children[0], singleton: @singleton_side)
          note_hook(owner, node.children[0])
          scan(node.children[2], nesting, forced_owner)
        when :defs
          # `def self.included(base)` — the common spelling of a hook, and one
          # the instance-method branch above never sees. It is also where a
          # reflection is shadowed on the side that matters: `Foo.method(:x)`
          # reaches `def self.method` before it reaches Kernel's.
          #
          # The receiver is READ rather than assumed to be `self`: `def
          # Foo.method(name)` written at the top level belongs to Foo, where
          # the nesting is empty and would have recorded nothing.
          owner = defs_owner(node.children[0], nesting, forced_owner)
          if owner
            block_method(owner, node.children[1], singleton: true)
            note_hook(owner, node.children[1])
          else
            # A receiver this cannot name — `def obj.method(name)`. Which class
            # gets the method is not readable here, so the name stops being
            # foldable anywhere rather than in a class this cannot point at.
            block_method_everywhere(node.children[1])
          end
          scan(node.children[3], nesting, forced_owner)
        when :sclass
          # `class << self` writes singleton methods with instance-method
          # syntax, so the bodies below have to know which side they are on.
          singleton = node.children[0]&.type == :self
          scan_side(singleton) { scan(node.children[1], nesting, forced_owner) }
        when :block
          send_node, _args, body = node.children
          if (owner = eval_owner(send_node, nesting))
            scan(body, owner.split("::"), owner)
          elsif (owner = refinement_owner(send_node, nesting))
            scan(body, owner.split("::"), owner)
          else
            scan(send_node, nesting, forced_owner)
            scan(body, nesting, forced_owner)
          end
        when :send
          owner = forced_owner || nesting.join("::")
          receiver, method_name, arguments = call_parts(node)

          target = receiver ? core_receiver(receiver, nesting) : (owner if CORE_CLASSES.include?(owner))
          # The same call on a class that is nobody's core: it can write a
          # reflection into it, and `taint` blocks exactly that much for one.
          # Not for a mixin, whose module IS read — a project module that
          # redefines a reflection is recorded under its own name, and the
          # receiver's ancestry is where the two meet.
          named = receiver ? named_receiver(receiver, nesting) : (owner unless owner.empty?)

          if LOOKUP_MUTATORS.include?(method_name) && target
            taint(target)
          elsif HOOK_MUTATORS.include?(method_name) && target
            # `include A, B` mixes in BOTH, so one inert module does not speak
            # for the call. The names are kept unresolved: which constant each
            # denotes depends on modules this may not have read yet.
            @mixins << [target, arguments.map { |argument| const_name(argument) }, nesting.dup]
          elsif EVAL_METHODS.include?(method_name) && named && !arguments.empty?
            # String/evaluated forms are opaque to the AST. Any method in the
            # target's lookup table could be replaced.
            taint(named)
          elsif METHOD_MUTATORS.include?(method_name) && target
            if method_name == :define_method || method_name == :alias_method
              note_hook(owner, literal_method_name(arguments.first))
              if (name = literal_method_name(arguments.first))
                block_method(target, name)
              else
                taint(target)
              end
            elsif arguments.empty?
              taint(target)
            else
              arguments.each do |argument|
                if (name = literal_method_name(argument))
                  block_method(target, name)
                else
                  taint(target)
                end
              end
            end
          end

          note_opaque_module(forced_owner || nesting.join("::"), method_name, arguments, target)

          node.children.each { |child| scan(child, nesting, forced_owner) }
        when :alias
          owner = forced_owner || nesting.join("::")
          if (aliased = literal_alias_name(node.children[0]))
            block_method(owner, aliased, singleton: @singleton_side)
            # `alias included install` gives the module a hook under a name the
            # `def` above never wrote.
            note_hook(owner, aliased)
          end
        when :undef
          owner = forced_owner || nesting.join("::")
          node.children.each { |name| block_method(owner, literal_method_name(name), singleton: @singleton_side) }
        else
          node.children.each { |child| scan(child, nesting, forced_owner) }
        end
      end

      # `Foo.class_eval { … }` writes into Foo, whatever Foo is: the block form
      # is READ, so what it defines is attributed rather than guessed at, and
      # that is as true of an app's class as of `Array`.
      def eval_owner(node, nesting)
        return nil unless node&.type == :send

        receiver, method_name, = call_parts(node)
        return nil unless EVAL_METHODS.include?(method_name)

        receiver ? named_receiver(receiver, nesting) : nil
      end

      def refinement_owner(node, nesting)
        return nil unless node&.type == :send

        _receiver, method_name, arguments = call_parts(node)
        return nil unless method_name == :refine

        core_receiver(arguments.first, nesting)
      end

      # `send`/`public_send`/`__send__` with a literal first argument names a
      # statically knowable call. Normalize that shape before looking for
      # method-table mutations so it cannot bypass the override registry.
      def call_parts(node)
        receiver, method_name, *arguments = node.children
        return [receiver, method_name, arguments] unless SEND_METHODS.include?(method_name)

        dispatched = literal_method_name(arguments.first)
        return [receiver, method_name, arguments] unless dispatched

        [receiver, dispatched.to_sym, arguments.drop(1)]
      end

      def core_receiver(node, nesting)
        name, absolute = const_name(node)
        return nil unless name

        # A bare `String` receiver can resolve to the top-level core constant
        # through Ruby's lexical constant lookup even inside another module.
        # Treating it as core is the conservative choice: a false positive only
        # disables folding, while a false negative could execute an override.
        return name if !absolute && !name.include?("::") && CORE_CLASSES.include?(name)

        resolved = absolute ? name : [*nesting, name].join("::")
        CORE_CLASSES.include?(resolved) ? resolved : nil
      end

      # The class a receiver NAMES, core or not, resolved the way Ruby's lexical
      # lookup would. nil for anything that is not a plain constant.
      def named_receiver(node, nesting)
        core = core_receiver(node, nesting)
        return core if core

        name, absolute = const_name(node)
        return nil unless name

        absolute ? name : [*nesting, name].join("::")
      end

      def const_name(node)
        return [nil, false] unless node&.type == :const

        parent, name = node.children
        return [name.to_s, false] unless parent
        return [name.to_s, true] if parent.type == :cbase

        prefix, absolute = const_name(parent)
        [prefix ? "#{prefix}::#{name}" : name.to_s, absolute]
      end

      def literal_method_name(node)
        return nil unless node.is_a?(::Parser::AST::Node)
        return node.children[0] if node.type == :sym || node.type == :str

        nil
      end

      def parse(content, path_name)
        buffer = ::Parser::Source::Buffer.new(path_name)
        buffer.source = content
        parser = ::Parser::Ruby33.new
        parser.diagnostics.all_errors_are_fatal = true
        parser.diagnostics.ignore_warnings = true
        parser.parse(buffer)
      end
    end
  end
end

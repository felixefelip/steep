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
      def self.build(project)
        new.tap { |r| r.build(project) }
      end

      def initialize
        @entries = {} #: Hash[String, Hash[Symbol, Integer]]
        @initializers = {} #: Hash[String, Array[TypeInference::ConstructorBindingAnalyzer::Body?]]
        @methods = {} #: Hash[String, Hash[Symbol, Array[TypeInference::ConstructorBindingAnalyzer::Body?]]]
        @memos = {} #: Hash[String, Hash[Symbol, Array[[Symbol, String]?]]]
        @uses = Hash.new { |hash, name| hash[name] = [] } #: Hash[Symbol, Array[TypeInference::ClassMemoAnalyzer::Use]]
      end

      # @return self
      def build(project)
        loader = Services::FileLoader.new(base_dir: project.base_dir)
        project.targets.each do |target|
          loader.each_path_in_target(target) do |relative_path|
            absolute = project.absolute_path(relative_path)
            next unless absolute.file?
            next unless ruby_source?(absolute)
            ingest(absolute)
          end
        end
        @entries.freeze
        @initializers.freeze
        @methods.freeze
        @memos.freeze
        @uses.default_proc = nil
        @uses.freeze
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

      # `[ivar, class name]` when `class_name.method_name` is the project's only
      # definition of it and is a memo (`TypeInference::ClassMemoAnalyzer`).
      def class_memo(class_name, method_name)
        memos = (@memos[class_name.to_s.delete_prefix("::")] || {})[method_name.to_sym] or return nil
        memos.first if memos.size == 1
      end

      # Every place the project names `name`, a method or an ivar, by spelling.
      def uses_of(name)
        @uses.fetch(name.to_sym, [])
      end

      # Whether the project may define `method_name` in `class_name` at all.
      def defines?(class_name, method_name)
        methods_of(class_name).key?(method_name.to_sym)
      end

      def empty?
        @entries.empty?
      end

      def to_h
        @entries
      end

      def ingest_source(content, path_name:)
        node = parse(content, path_name)
        return unless node
        scan = TypeInference::ConstructorBindingAnalyzer.scan(node)
        scan.readers.each do |class_name, readers|
          (@entries[class_name] ||= {}).merge!(readers)
        end
        scan.initializers.each do |class_name, initializers|
          (@initializers[class_name] ||= []).concat(initializers)
        end
        scan.methods.each do |class_name, methods|
          entry = (@methods[class_name] ||= {})
          methods.each { |name, bodies| (entry[name] ||= []).concat(bodies) }
        end
        ingest_memos(node)
      rescue StandardError, ::Parser::SyntaxError => e
        Steep.logger.warn { "[constructor_binding_registry] failed to ingest #{path_name}: #{e.message}" }
      end

      private

      def ingest_memos(node)
        scan = TypeInference::ClassMemoAnalyzer.scan(node)
        scan.memos.each do |class_name, memos|
          entry = (@memos[class_name] ||= {})
          memos.each { |name, found| (entry[name] ||= []).concat(found) }
        end
        scan.uses.each { |name, uses| @uses[name].concat(uses) }
      end

      def methods_of(class_name)
        @methods[class_name.to_s.delete_prefix("::")] || {}
      end

      def ruby_source?(path)
        ext = path.extname
        ext == ".rb" || ext == ".rake"
      end

      def ingest(absolute_path)
        ingest_source(absolute_path.read, path_name: absolute_path.to_s)
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

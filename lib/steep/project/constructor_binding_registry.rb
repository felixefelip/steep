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
    # classes have no Ruby body to analyze and are simply absent — `lookup`
    # returns nil and the caller falls through.
    class ConstructorBindingRegistry
      def self.build(project)
        new.tap { |r| r.build(project) }
      end

      def initialize
        @entries = {} #: Hash[String, Hash[Symbol, Integer]]
        @ivar_facts = {} #: Hash[String, TypeInference::ImmutableIvarAnalyzer::ClassFacts]
        @tainted_ivars = Set[] #: Set[Symbol]
        @taint_all = false
        @module_writes = Set[] #: Set[Symbol]
        @extends_objects = false
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
        @ivar_facts.freeze
        self
      end

      # @param class_name [String, #to_s] absolute (`"::Proxy"`) or bare
      # @param reader [Symbol, #to_sym]
      # @return [Integer, nil] the constructor parameter index, or nil
      def lookup(class_name, reader)
        key = class_name.to_s.sub(/\A::/, "")
        @entries.dig(key, reader.to_sym)
      end

      # @param class_name [String, #to_s]
      # @return [Hash[Symbol, Integer], nil] all reader→index bindings for the
      #   class, or nil when it has none
      def bindings_for(class_name)
        @entries[class_name.to_s.sub(/\A::/, "")]
      end

      # The ivars every `class_name.new(…)` fixes for the object's whole life,
      # by the positional argument each is assigned from (felixefelip/steep#205,
      # stage 1). `{ :@name => 0 }` says `Reflection.new(:posts)` holds `:posts`
      # in `@name` under any name that reaches it, from the call on.
      #
      # Over the whole project: one `initialize`, binding the ivar straight from
      # a parameter, and nothing else anywhere writing it — no other method, no
      # `attr_writer`, no `class_eval` block, no `instance_variable_set`. A class
      # with a superclass or a mixin answers nothing, since the code that may
      # write is then code this index does not attribute to it.
      def immutable_ivar_bindings_for(class_name)
        return {} if @taint_all

        facts = @ivar_facts[class_name.to_s.delete_prefix("::")] or return {}
        return {} unless facts.initializers == 1 && facts.bindings
        return {} if facts.superclass || facts.mixins

        facts.bindings.reject do |ivar, _|
          facts.written.include?(ivar) || @tainted_ivars.include?(ivar) ||
            (@extends_objects && @module_writes.include?(ivar))
        end
      end

      def empty?
        @entries.empty?
      end

      def to_h
        @entries
      end

      def ingest_source(content, path_name:)
        node, readable = parse(content, path_name)
        # A source this could not read may write anything. One with nothing in
        # it — empty, or comments only — parses to nil and writes nothing.
        @taint_all = true unless readable
        return unless node
        bindings = TypeInference::ConstructorBindingAnalyzer.analyze(node)
        bindings.each do |class_name, readers|
          (@entries[class_name] ||= {}).merge!(readers)
        end
        merge_ivar_scan(TypeInference::ImmutableIvarAnalyzer.analyze(node))
      rescue StandardError, ::Parser::SyntaxError => e
        # A source this could not read may write anything.
        @taint_all = true
        Steep.logger.warn { "[constructor_binding_registry] failed to ingest #{path_name}: #{e.message}" }
      end

      private

      def ruby_source?(path)
        ext = path.extname
        ext == ".rb" || ext == ".rake"
      end

      def ingest(absolute_path)
        ingest_source(absolute_path.read, path_name: absolute_path.to_s)
      end

      def merge_ivar_scan(scan)
        @tainted_ivars.merge(scan.tainted)
        @taint_all ||= scan.taint_all
        @module_writes.merge(scan.module_writes)
        @extends_objects ||= scan.extends_objects

        scan.classes.each do |name, facts|
          merged = @ivar_facts[name] ||= TypeInference::ImmutableIvarAnalyzer::ClassFacts.empty
          merged.bindings = facts.bindings if facts.bindings
          merged.initializers += facts.initializers
          merged.written.merge(facts.written)
          merged.superclass ||= facts.superclass
          merged.mixins ||= facts.mixins
        end
      end

      # The tree, and whether the source was read without an error.
      def parse(content, path_name)
        buffer = ::Parser::Source::Buffer.new(path_name)
        buffer.source = content
        parser = ::Parser::Ruby33.new
        parser.diagnostics.all_errors_are_fatal = false
        parser.diagnostics.ignore_warnings = true
        errors = false
        parser.diagnostics.consumer = ->(diagnostic) { errors = true if diagnostic.level == :error }
        node = parser.parse(buffer)
        [node, !errors]
      rescue ::Parser::SyntaxError
        [nil, false]
      end
    end
  end
end

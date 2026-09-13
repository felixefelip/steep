module Steep
  class Project
    # Conservative project-wide record of Ruby source that can replace one of
    # LiteralIntrinsics' core implementations. RBS method declarations identify
    # the owner and name, but a Ruby reopen has the same owner and name; this
    # source index supplies the missing implementation provenance.
    class LiteralMethodRegistry
      CORE_CLASSES = Set["String", "Integer", "Symbol"]
      LOOKUP_MUTATORS = Set[:include, :prepend, :extend]
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
        @blocked = Set[] #: Set[String]
      end

      def initialize_copy(original)
        super
        @blocked = original.to_set
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
        @blocked.include?(normalize(method_name))
      end

      def empty?
        @blocked.empty?
      end

      def to_set
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

      def block_method(owner, method_name)
        return unless CORE_CLASSES.include?(owner)

        key = "::#{owner}##{method_name}"
        @blocked << key if LiteralIntrinsics::ENTRIES.key?(key)
      end

      def taint(owner)
        return unless CORE_CLASSES.include?(owner)

        @blocked.merge(LiteralIntrinsics.method_keys_for(owner))
      end

      def taint_all
        CORE_CLASSES.each { |owner| taint(owner) }
      end

      def scan(node, nesting, forced_owner = nil)
        return unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :class, :module
          name, absolute = const_name(node.children[0])
          owner = absolute ? name : [*nesting, name].compact.join("::")
          body = node.type == :class ? node.children[2] : node.children[1]
          scan(body, owner.split("::"), nil)
        when :def
          owner = forced_owner || nesting.join("::")
          block_method(owner, node.children[0])
          scan(node.children[2], nesting, forced_owner)
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

          if LOOKUP_MUTATORS.include?(method_name) && target
            taint(target)
          elsif EVAL_METHODS.include?(method_name) && target && !arguments.empty?
            # String/evaluated forms are opaque to the AST. Any method in the
            # target's lookup table could be replaced.
            taint(target)
          elsif METHOD_MUTATORS.include?(method_name) && target
            if method_name == :define_method || method_name == :alias_method
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

          node.children.each { |child| scan(child, nesting, forced_owner) }
        when :alias
          owner = forced_owner || nesting.join("::")
          block_method(owner, literal_method_name(node.children[0])) if node.children[0]
        when :undef
          owner = forced_owner || nesting.join("::")
          node.children.each { |name| block_method(owner, literal_method_name(name)) }
        else
          node.children.each { |child| scan(child, nesting, forced_owner) }
        end
      end

      def eval_owner(node, nesting)
        return nil unless node&.type == :send

        receiver, method_name, = call_parts(node)
        return nil unless EVAL_METHODS.include?(method_name)

        receiver ? core_receiver(receiver, nesting) : nil
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

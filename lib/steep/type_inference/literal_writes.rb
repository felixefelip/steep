module Steep
  module TypeInference
    # The ivars a body only ever sets to a hash or array literal, and the
    # calls made on one: such an ivar holds a plain `Hash` or `Array`, never an
    # object of a class the project defines.
    module LiteralWrites
      COLLECTIONS = %i[hash array].freeze

      module_function

      # The ivars of `writes` that every assignment `body` makes sets to a
      # hash or array literal.
      def of(body, writes)
        literal = Set[].compare_by_identity #: Set[::Parser::AST::Node]
        nodes(body) do |node|
          target, value = node.children
          literal << target if %i[or_asgn and_asgn].include?(node.type) && COLLECTIONS.include?(value.type)
          literal << node if node.type == :ivasgn && COLLECTIONS.include?(value&.type)
        end
        nodes(body) { |node| writes -= [node.children[0]] if node.type == :ivasgn && !literal.include?(node) }
        writes
      end

      # Whether `call` is made on an ivar that every instance method of
      # `methods` (`{ class name => { method name => [Body or nil] } }`)
      # assigns only a literal, and names a method the project does not define
      # on `Hash` or `Array`. A body this cannot read may assign it anything.
      # `related`, given a class name, says whether its ivars can be the
      # call's at all; without it, those of any class can.
      def receiver?(call, methods, related: nil)
        ivar = call.on_ivar or return false
        return false if %w[Hash Array].any? { |name| methods.fetch(name, {}).key?(call.called) }

        methods.all? do |class_name, bodies_by_name|
          bodies_by_name.each_value.all? { |bodies| bodies.all? { |body| body && (!body.writes.include?(ivar) || body.literal_writes&.include?(ivar)) } } ||
            (related && !related.call(class_name))
        end
      end

      # `receiver?` for a call on an ivar of a class object, made in a class
      # method or a class body: `singleton_methods` and the class bodies of
      # `class_bodies` (`record_class_body`) are what assign it, and at least
      # one of them must set it to a literal.
      def class_object_receiver?(call, singleton_methods, class_bodies, related: nil)
        ivar = call.on_ivar or return false
        bodies = class_bodies.select { |class_name, ivars| ivars.key?(ivar) && (!related || related.call(class_name)) }
        literal = !bodies.empty? || singleton_methods.any? do |class_name, bodies_by_name|
          (!related || related.call(class_name)) && bodies_by_name.each_value.any? { |each| each.any? { |body| body&.literal_writes&.include?(ivar) } }
        end
        literal && bodies.each_value.all? { |ivars| ivars[ivar] } && receiver?(call, singleton_methods, related: related)
      end

      # Adds to `index`, under each of `names`, the ivars `body`, a class or
      # module body, assigns outside its methods, each true where every one of
      # those assignments sets a hash or array literal.
      def record_class_body(index, names, body)
        written = in_class_body(body, {})
        names.each { |name| (index[name] ||= {}).merge!(written) { |_, kept, more| kept && more } } unless written.empty?
      end

      def in_class_body(node, written)
        return written unless node.is_a?(::Parser::AST::Node) && !%i[def defs class module sclass].include?(node.type)

        target, value = %i[or_asgn and_asgn].include?(node.type) ? node.children : [node, node.children[1]]
        written[target.children[0]] = written.fetch(target.children[0], true) && COLLECTIONS.include?(value&.type) if target.type == :ivasgn
        (target.equal?(node) ? node.children : [value]).each { |child| in_class_body(child, written) }
        written
      end

      def nodes(node, &block)
        return unless node.is_a?(::Parser::AST::Node)

        yield node
        node.children.each { |child| nodes(child, &block) }
      end
    end
  end
end

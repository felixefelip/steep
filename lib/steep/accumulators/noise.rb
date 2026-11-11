module Steep
  module Accumulators
    # Where a statement may run code this walk does not read: a call on
    # anything but a watched local or a literal, a `yield`, a write outside the
    # locals. Such code may change an array a method answered through the other
    # names it has (`Built#exposed`).
    module Noise
      module_function

      LITERALS = %i[int float str sym nil true false rational complex].freeze

      # The nodes that run nothing of their own beyond their children.
      QUIET = (LITERALS + %i[self lvar lvasgn array begin and or if irange erange splat const]).freeze

      # The noisy nodes that run their children before they run themselves.
      AFTER_CHILDREN = %i[send csend yield super zsuper ivasgn gvasgn cvasgn casgn dstr dsym xstr].freeze

      # The noise in `statement` that may run before `site` is evaluated.
      def before(statement, site, locals)
        start = site.loc.expression&.begin_pos
        points(statement, locals).select do |point|
          range = point.loc.expression
          !start || !range || range.end_pos <= start || (contains?(point, site) && !AFTER_CHILDREN.include?(point.type))
        end
      end

      # Whether every point that exposed a local is a call the checker resolved
      # to a core read that runs no code of the project's (`self.class`).
      def harmless?(constr, points)
        points.all? do |point|
          call = constr.typing.call_of(node: point)
          call.is_a?(TypeInference::MethodCall::Typed) &&
            CollectionMutation.only?(constr, call.method_decls.map { |decl| MethodIdentity.normalize(decl.method_name.to_s) }.uniq, CollectionMutation::OBJECT_READS)
        rescue Typing::UnknownNodeError
          false
        end
      end

      def points(node, locals, found = [])
        return found unless node.is_a?(Parser::AST::Node)

        found << node unless quiet?(node, locals)
        node.children.each { |child| points(child, locals, found) }
        found
      end

      def quiet?(node, locals)
        case node.type
        when *QUIET then true
        when :send, :csend then held?(node.children[0], locals)
        else false
        end
      end

      # A receiver no call on can reach code outside: a watched local, a
      # literal, or what a call on one of those answered.
      def held?(node, locals)
        return false unless node.is_a?(Parser::AST::Node)

        case node.type
        when :lvar then locals.include?(node.children[0])
        when *LITERALS then true
        when :begin then node.children.size == 1 && held?(node.children[0], locals)
        when :send, :csend then held?(node.children[0], locals)
        else false
        end
      end

      def contains?(outer, inner)
        return true if outer.equal?(inner)

        outer.children.any? { |child| child.is_a?(Parser::AST::Node) && contains?(child, inner) }
      end

      def heard(statement, site, contents, elements)
        expose(elements, before(statement, site, contents.keys))
      end

      def around(statement, contents, pushed)
        noise = points(statement, contents.keys)
        expose_names(contents, pushed, noise)
        yield
        expose_names(contents, contents.keys, noise)
      end

      def expose_names(contents, names, noise)
        names.each { |name| contents[name] = expose(contents.fetch(name), noise) }
      end

      def expose(elements, noise)
        return elements if noise.empty?

        elements.map do |element|
          case element
          when Built then Built.new(element.node, element.exposed + noise)
          when Reshaped then Reshaped.new(element.key, element.fold_key, expose(element.elements, noise))
          when Mapped then Mapped.new(element.block, expose(element.elements, noise))
          else element
          end
        end
      end
    end
  end
end

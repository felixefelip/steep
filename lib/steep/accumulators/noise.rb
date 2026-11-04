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
      QUIET = (LITERALS + %i[lvar lvasgn array begin and or if irange erange splat const]).freeze

      # The noisy nodes that run their children before they run themselves.
      AFTER_CHILDREN = %i[send csend yield super zsuper ivasgn gvasgn cvasgn casgn dstr dsym xstr].freeze

      def any?(statement, locals)
        !points(statement, locals).empty?
      end

      # Whether noise in `statement` may run before `site` is evaluated.
      def before?(statement, site, locals)
        start = site.loc.expression&.begin_pos or return true

        points(statement, locals).any? do |point|
          range = point.loc.expression or next true
          range.end_pos <= start || (contains?(point, site) && !AFTER_CHILDREN.include?(point.type))
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
        before?(statement, site, contents.keys) ? expose(elements) : elements
      end

      def around(statement, contents, pushed)
        noisy = any?(statement, contents.keys)
        expose_names(contents, pushed) if noisy
        yield
        expose_names(contents, contents.keys) if noisy
      end

      def expose_names(contents, names)
        names.each { |name| contents[name] = expose(contents.fetch(name)) }
      end

      def expose(elements)
        elements.map do |element|
          case element
          when Built then element.exposed ? element : Built.new(element.node, true)
          when Reshaped then Reshaped.new(element.key, element.fold_key, expose(element.elements))
          when Mapped then Mapped.new(element.block, expose(element.elements))
          else element
          end
        end
      end
    end
  end
end

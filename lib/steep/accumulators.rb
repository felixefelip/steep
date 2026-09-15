module Steep
  # Locals that hold an array built by `<<`, and whose contents a body can be
  # read to know.
  #
  #     parts = []
  #     parts << "a"
  #     parts << "b"
  #     parts.join(";")      # "a;b", once the local carries the tuple
  #
  # The type of an array says what its elements are and never how many, so the
  # contents can only come from reading the pushes. That is sound exactly while
  # nothing else can reach the array — which is what this decides, and it
  # decides it conservatively: a local it cannot vouch for is simply not one of
  # these, and the checker goes on typing it as it does today.
  #
  # The dangerous answer is not an imprecise one, it is a CONFIDENT WRONG one:
  #
  #     parts = []
  #     other = parts
  #     other << "a"
  #     parts.join(";")      # "a" at runtime; "" to anything tracking `parts`
  #
  # so every way the array can be reached under another name disqualifies the
  # local: assigned to a second name, passed as an argument, returned, stored,
  # or pushed inside a block (where nothing here knows how many times the push
  # runs). What is left is a local that is born from an array literal, pushed to
  # in a straight line, and read.
  module Accumulators
    # Methods that read an array without letting it escape. Anything else on the
    # receiver — including one that merely looks harmless — is not on this list
    # because the list is the claim.
    READERS = %i[join first last size length empty? count fetch [] include?].freeze

    class << self
      # `{ name => [element node, …] }` for every local in `def_node` whose
      # contents this can read, with the pushes in the order they happen.
      #
      # Only the body's STRAIGHT LINE is read: a statement of the method itself,
      # not one inside an `if`, a loop or a block. That is the whole soundness
      # argument and it is deliberately blunt —
      #
      #     parts << "b" if flag        # one content or two, and no way to know
      #     names.each { parts << x }   # read once, runs any number of times
      #
      # — so a push this cannot count simply disqualifies the local. Every other
      # mention of the name disqualifies it too: `other = parts` and
      # `fill(parts)` both hand the array to someone who can push into it, and a
      # tracker that answered anyway would be confidently wrong rather than
      # vague.
      def in_body(def_node)
        body = body_of(def_node) or return {}

        found = {} #: Hash[Symbol, Array[untyped]?]
        statements(body).each { |statement| read(statement, found) }
        found.reject { |_, pushes| pushes.nil? }
      end

      # `{ read node => [element node, …] }` — what the array holds where it is
      # READ, for every local this vouches for.
      #
      # Keyed by the read because that is the question the checker asks: it is
      # standing on `parts.join(";")` and wants the contents there. The contents
      # are handed to the fold rather than written into the type environment —
      # refining the local makes `Array[Elem]#<<` demand the first element's
      # type, so the NEXT push stops type-checking:
      #
      #     parts << "a"      # parts becomes ["a"]
      #     parts << "b"      # error: `::String` is not `"a"`
      #
      # The contents are the same either way; this is the half that has no blast
      # radius.
      def contents_at_reads(node)
        # BY IDENTITY. Parser nodes compare structurally, so `parts.join(";")`
        # written in two methods is one key — and the second would be answered
        # with the first one's contents. The nodes walked here are the ones the
        # checker types, so identity is both available and the only thing that
        # distinguishes them.
        result = {}.compare_by_identity #: Hash[untyped, Array[untyped]]

        each_def(node) do |def_node|
          body = body_of(def_node) or next

          readable = in_body(def_node)
          next if readable.empty?

          contents = readable.keys.to_h { |name| [name, seed_of(body, name)] }
          statements(body).each do |statement|
            if (push = push_onto(statement, contents))
              name, value = push
              contents[name] = contents.fetch(name) + [value]
              next
            end

            each_node(statement) do |child|
              next unless child.type == :send && READERS.include?(child.children[1])

              receiver = child.children[0]
              next unless receiver&.type == :lvar && contents.key?(receiver.children[0])

              result[child] = contents.fetch(receiver.children[0])
            end
          end
        end

        result
      end

      private

      def body_of(def_node)
        def_node.type == :defs ? def_node.children[3] : def_node.children[2]
      end

      def each_node(node, &block)
        return unless node.is_a?(Parser::AST::Node)

        yield node
        node.children.each { |child| each_node(child, &block) }
      end

      def each_def(node, &block)
        return unless node.is_a?(Parser::AST::Node)

        yield node if node.type == :def || node.type == :defs
        node.children.each { |child| each_def(child, &block) }
      end

      # The elements the local was born with, which the pushes extend.
      def seed_of(body, name)
        statements(body).each do |statement|
          next unless statement.type == :lvasgn && statement.children[0] == name
          return array_literal?(statement.children[1]) ? statement.children[1].children.dup : []
        end

        []
      end

      def statements(body)
        return [] unless body.is_a?(Parser::AST::Node)

        body.type == :begin ? body.children : [body]
      end

      # One statement of the straight line. It either seeds a local, pushes onto
      # one, or is everything else — and everything else only takes locals away.
      def read(statement, found)
        return unless statement.is_a?(Parser::AST::Node)

        if statement.type == :lvasgn && array_literal?(statement.children[1])
          name = statement.children[0]
          # A second assignment is a different array, and nothing here orders
          # the two.
          found[name] = found.key?(name) ? nil : statement.children[1].children.dup
          return
        end

        if (push = push_onto(statement, found))
          name, value = push
          found[name] = found[name] + [value]
          return
        end

        strike(statement, found)
      end

      def push_onto(statement, found)
        return nil unless statement.type == :send && statement.children[1] == :<<

        receiver = statement.children[0]
        return nil unless receiver&.type == :lvar

        name = receiver.children[0]
        return nil unless found[name]

        [name, statement.children[2]]
      end

      def array_literal?(node)
        node.is_a?(Parser::AST::Node) && node.type == :array &&
          node.children.none? { |child| child.type == :splat }
      end

      # Every local this statement so much as names stops being readable, except
      # where it is the receiver of a call that only READS the array.
      def strike(node, found)
        return unless node.is_a?(Parser::AST::Node)

        if node.type == :send && READERS.include?(node.children[1]) && node.children[0]&.type == :lvar
          node.children.drop(2).each { |argument| strike(argument, found) }
          return
        end

        if node.type == :lvar
          name = node.children[0]
          found[name] = nil if found.key?(name)
          return
        end

        node.children.each { |child| strike(child, found) }
      end
    end

  end
end

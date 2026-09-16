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
  # or mentioned inside a block (where nothing here knows WHEN, or how many
  # times, that body runs). What is left is a local that is born from an array
  # literal, pushed to in a straight line, and read.
  #
  # Three boundaries this must not cross, each of which is a way to name one
  # array and read another:
  #
  #     result = parts.join(";")   # BEFORE the array exists — a read of
  #     parts = []                 # something else entirely
  #
  #     reader = -> { parts.join(";") }   # runs later; the contents here are
  #     parts << "b"                      # not the contents there
  #
  #     def inner(parts)           # a body of its own: this `parts` is a
  #       parts.join(";")          # different variable that shares a name
  #     end
  module Accumulators
    # Methods that read an array without letting it escape. Anything else on the
    # receiver — including one that merely looks harmless — is not on this list
    # because the list is the claim.
    READERS = %i[join first last size length empty? count fetch [] include?].freeze

    # Nodes that open a body of their own. A local named inside one is a
    # DIFFERENT variable that happens to share a name, so nothing outside says
    # anything about it and nothing inside says anything about the outside.
    SCOPES = %i[def defs class module sclass].freeze

    # Nodes whose body closes over the locals around it but runs on its own
    # schedule — an argument-position block, a lambda, a `numblock`. What the
    # array holds when one is WRITTEN is not what it holds when the body runs,
    # so a mention inside one takes the local away.
    CLOSURES = %i[block numblock].freeze

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
        lines = statements(body)
        # The value a body ENDS on leaves it, and nothing in this body runs
        # afterwards to be told a lie about it. `parts` written last is the
        # array as it stands, which is exactly what the caller receives — so it
        # is read rather than struck, where `fill(parts)` in the middle is still
        # struck because what follows could read the array the callee changed.
        returned = returned_local(lines.last)

        lines.each_with_index do |statement, index|
          next if index == lines.size - 1 && returned

          read(statement, found)
        end

        found.reject { |_, pushes| pushes.nil? }
      end

      # What one walk of a whole source says, for the checker to ask node by
      # node. Both halves come out of the SAME replay — the reads and the last
      # pushes are two things to notice about one pass over a body, and walking
      # twice would cost the file's AST twice for no second answer.
      #
      # `at_reads` — `{ read node => [element node, …] }`, what the array holds
      # where it is READ. Keyed by the read because that is the question the
      # checker asks: it is standing on `parts.join(";")` and wants the contents
      # there. Those go to the fold and nowhere near the type environment, since
      # refining the local makes `Array[Elem]#<<` demand the first element's
      # type and the NEXT push stops type-checking:
      #
      #     parts << "a"      # parts becomes ["a"]
      #     parts << "b"      # error: `::String` is not `"a"`
      #
      # `final` — `{ last push node => [element node, …] }`, the contents of
      # every readable local at the push that completes them. This half the type
      # environment does hear about, and the LAST push is the one place where it
      # is safe to say so: after it there is no `<<` left to demand anything, and
      # what the local is worth from there on is exactly the tuple `return parts`
      # hands back.
      Analysis = Struct.new(:at_reads, :final, keyword_init: true)

      # Both maps, from one pass. Ask a `Source` for this rather than calling it
      # per method — `Source#accumulators` holds the answer for the whole file,
      # and a `TypeConstruction` is built anew for every method body.
      def analyze(node)
        # BY IDENTITY, both of them. Parser nodes compare structurally, so
        # `parts.join(";")` written in two methods is one key — and the second
        # would be answered with the first one's contents. The nodes walked here
        # are the ones the checker types, so identity is both available and the
        # only thing that distinguishes them.
        at_reads = {}.compare_by_identity #: Hash[untyped, Array[untyped]]
        final = {}.compare_by_identity #: Hash[untyped, Array[untyped]]

        each_def(node) do |def_node|
          last = {} #: Hash[Symbol, [untyped, Array[untyped]]]

          replay(def_node) do |statement, pushed, contents|
            if pushed
              last[pushed] = [statement, contents.fetch(pushed)]
              next
            end

            each_node(statement) do |child|
              next unless child.type == :send && READERS.include?(child.children[1])

              receiver = child.children[0]
              next unless receiver&.type == :lvar && contents.key?(receiver.children[0])

              at_reads[child] = contents.fetch(receiver.children[0])
            end
          end

          last.each_value { |statement, elements| final[statement] = elements }
        end

        Analysis.new(at_reads: at_reads, final: final)
      end

      def contents_at_reads(node)
        analyze(node).at_reads
      end

      def final_contents(node)
        analyze(node).final
      end

      private

      # Replays one body, yielding each statement with the name it pushes onto
      # (nil where it pushes onto nothing) and the contents of every readable
      # local as they stand AFTER that push. Yields nothing for a body this
      # vouches for no local in.
      #
      # A local enters `contents` where its assignment is REACHED, never before:
      # seeding the whole body up front would make the array available
      # retroactively, so `parts.join(";")` written ABOVE `parts = []` would be
      # answered with the contents of an array that does not exist yet — while
      # the `parts` it actually reads is whatever else that name holds there, a
      # method argument included.
      def replay(def_node)
        body = body_of(def_node) or return

        readable = in_body(def_node)
        return if readable.empty?

        contents = {} #: Hash[Symbol, Array[untyped]]
        statements(body).each do |statement|
          if (seed = seed_from(statement)) && readable.key?(seed[0])
            contents[seed[0]] = seed[1]
            yield statement, nil, contents
            next
          end

          name, value = push_onto(statement, contents)
          contents[name] = contents.fetch(name) + [value] if name

          yield statement, name, contents
        end
      end

      def body_of(def_node)
        def_node.type == :defs ? def_node.children[3] : def_node.children[2]
      end

      # Every node of one statement, stopping at a body of its own — `parts`
      # inside a nested `def` is that def's variable, and answering its read
      # with the contents out here is an answer about a different array.
      def each_node(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        return if SCOPES.include?(node.type)

        yield node
        node.children.each { |child| each_node(child, &block) }
      end

      def each_def(node, &block)
        return unless node.is_a?(Parser::AST::Node)

        yield node if node.type == :def || node.type == :defs
        node.children.each { |child| each_def(child, &block) }
      end

      # `[name, elements]` where this statement is a local born from an array
      # literal, the only birth this vouches for.
      def seed_from(statement)
        return nil unless statement.is_a?(Parser::AST::Node)
        return nil unless statement.type == :lvasgn && array_literal?(statement.children[1])

        [statement.children[0], statement.children[1].children.dup]
      end

      # The local a body hands back, for `parts` or `return parts` written last.
      def returned_local(statement)
        return nil unless statement.is_a?(Parser::AST::Node)

        node = statement.type == :return ? statement.children[0] : statement
        node&.type == :lvar ? node.children[0] : nil
      end

      def statements(body)
        return [] unless body.is_a?(Parser::AST::Node)

        body.type == :begin ? body.children : [body]
      end

      # One statement of the straight line. It either seeds a local, pushes onto
      # one, or is everything else — and everything else only takes locals away.
      def read(statement, found)
        return unless statement.is_a?(Parser::AST::Node)

        if (seed = seed_from(statement))
          name, elements = seed
          # A second assignment is a different array, and nothing here orders
          # the two.
          found[name] = found.key?(name) ? nil : elements
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
      # where it is the receiver of a call that only READS the array — and not
      # even then inside a closure, whose body runs at a time this walk does not
      # know.
      def strike(node, found, closure: false)
        return unless node.is_a?(Parser::AST::Node)
        # Another body's locals, not these.
        return if SCOPES.include?(node.type)

        if CLOSURES.include?(node.type)
          node.children.each { |child| strike(child, found, closure: true) }
          return
        end

        # WRITTEN, so the pushes recorded so far were into an array the name no
        # longer holds:
        #
        #     parts = []
        #     parts << "a"
        #     parts = Array.new   # ← a different array from here on
        #     parts << "b"        #   `["b"]`, and `["a", "b"]` to anything
        #     parts               #   still counting from the first one
        #
        # Reached for every shape of write, because `op_asgn`, `or_asgn`,
        # `and_asgn` and each target of an `masgn` all hold an `lvasgn` of their
        # own. The one write that does NOT come through here is the birth
        # `parts = []`, which `read` takes before striking — and a SECOND one of
        # those it strikes itself, for this same reason.
        if node.type == :lvasgn
          name = node.children[0]
          found[name] = nil if found.key?(name)
          strike(node.children[1], found, closure: closure)
          return
        end

        if !closure && node.type == :send && READERS.include?(node.children[1]) && node.children[0]&.type == :lvar
          node.children.drop(2).each { |argument| strike(argument, found, closure: closure) }
          return
        end

        if node.type == :lvar
          name = node.children[0]
          found[name] = nil if found.key?(name)
          return
        end

        node.children.each { |child| strike(child, found, closure: closure) }
      end
    end

  end
end

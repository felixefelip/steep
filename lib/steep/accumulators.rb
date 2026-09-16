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
  #
  # An array that NO local holds — one written out where the body ends — is the
  # same question reached from the other side. There is no name to reach it
  # under, so there is nothing to disqualify and the contents are simply what
  # the source says; `Analysis#returned` is that half.
  #
  # A CALL is the boundary this is least willing to cross, and the one worth
  # crossing:
  #
  #     parts = []
  #     fill(parts)          # `fill` pushes; nothing about `parts` is written
  #     parts.join(";")      # "a" at runtime, "" to anything following the name
  #
  # so `fill(parts)` takes the local away, and rightly — unless the body of
  # `fill` is one this walk HAS. A method of the same class written in this file
  # is such a body, and if all it does with the parameter is append to it, what
  # the call does to the array is as readable as a `<<` written here. Anything
  # else — a receiver, another file, a name defined twice, a parameter the
  # callee does more than append to — is a body this does not have, and the
  # local goes away as before.
  module Accumulators
    # Shared with `Constants`, which vouches for a value on the same terms. See
    # `CollectionReaders` for why a call is on the list or is not.
    READERS = CollectionReaders::METHODS

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
      def in_body(def_node, builders)
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

          read(statement, found, builders)
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
      # `final` — `{ last push node => { name => [element node, …] } }`, the
      # contents of every readable local at the statement that completes them.
      # This half the type environment does hear about, and the LAST push is the
      # one place where it is safe to say so: after it there is no `<<` left to
      # demand anything, and what the local is worth from there on is exactly
      # the tuple `return parts` hands back. Keyed by name as well as by node
      # because one `fill(parts, others)` can complete more than one.
      #
      # `returned` — the array LITERALS a body hands back. Nothing has to be
      # replayed for these: what is in one is written in it, and the only
      # question was whether anything here could change it before it leaves.
      Analysis = Struct.new(:at_reads, :final, :returned, keyword_init: true)

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
        final = {}.compare_by_identity #: Hash[untyped, Hash[Symbol, Array[untyped]]]
        returned = {}.compare_by_identity #: Hash[untyped, bool]

        builders = builders_in(node)

        each_def_with_owner(node) do |def_node, owner|
          each_returned(def_node) { |array| returned[array] = true }

          last = {} #: Hash[Symbol, [untyped, Array[untyped]]]

          replay(def_node, builders_for(builders, owner, def_node)) do |statement, pushed, contents|
            unless pushed.empty?
              pushed.each { |name| last[name] = [statement, contents.fetch(name)] }
              next
            end

            each_node(statement) do |child|
              next unless child.type == :send && READERS.include?(child.children[1])

              receiver = child.children[0]
              next unless receiver&.type == :lvar && contents.key?(receiver.children[0])

              at_reads[child] = contents.fetch(receiver.children[0])
            end
          end

          last.each do |name, (statement, elements)|
            (final[statement] ||= {})[name] = elements
          end
        end

        Analysis.new(at_reads: at_reads, final: final, returned: returned)
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
      def replay(def_node, builders)
        body = body_of(def_node) or return

        readable = in_body(def_node, builders)
        return if readable.empty?

        contents = {} #: Hash[Symbol, Array[untyped]]
        statements(body).each do |statement|
          if (seed = seed_from(statement)) && readable.key?(seed[0])
            contents[seed[0]] = seed[1]
            yield statement, [], contents
            next
          end

          pushed = [] #: Array[Symbol]

          if (built = builds_onto(statement, contents, builders))
            built.each do |name, elements|
              contents[name] = contents.fetch(name) + elements
              pushed << name
            end
          elsif (push = push_onto(statement, contents))
            name, value = push
            contents[name] = contents.fetch(name) + [value]
            pushed << name
          end

          yield statement, pushed, contents
        end
      end

      def body_of(def_node)
        def_node.type == :defs ? def_node.children[3] : def_node.children[2]
      end

      # Every array literal in a position `def_node`'s value leaves from.
      #
      # Written out rather than spelled `hint`: the return type reaches exactly
      # these positions while it is being CHECKED against, but it reaches
      # argument positions and typed assignments the same way, and those are
      # places where a name does hold the array.
      def each_returned(def_node)
        body = body_of(def_node) or return

        literal = ->(node) do
          # An empty literal is the one the checker already asks to be
          # annotated, and a tuple of nothing is not an answer to that.
          yield node if array_literal?(node) && !node.children.empty?
        end

        each_tail(body, &literal)
        each_returns(body, &literal)
      end

      # The ends of one body: the statement it finishes on, and — because a body
      # that finishes on an `if` finishes on whichever arm ran — the ends inside
      # that. `return` is the same thing written earlier, so it is followed from
      # wherever it appears, through a block (which returns from the method
      # around it) but not into a body of its own.
      def each_tail(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        return if SCOPES.include?(node.type)

        case node.type
        when :begin, :kwbegin
          each_tail(node.children.last, &block)
        when :if
          each_tail(node.children[1], &block)
          each_tail(node.children[2], &block)
        when :case, :case_match
          node.children.drop(1).each do |branch|
            next unless branch.is_a?(Parser::AST::Node)

            arm = branch.type == :when || branch.type == :in_pattern ? branch.children.last : branch
            each_tail(arm, &block)
          end
        when :return
          each_tail(node.children[0], &block)
        else
          yield node
        end
      end

      # `return` written anywhere but the end — inside an `if` that guards, in a
      # block, wherever. The value leaves from there just the same.
      def each_returns(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        return if SCOPES.include?(node.type)

        node.children.each do |child|
          next unless child.is_a?(Parser::AST::Node)

          child.type == :return ? each_tail(child, &block) : each_returns(child, &block)
        end
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

      # Every `def` with the `class`/`module`/`sclass` node it is written in, or
      # nil where it is written at the top level. The owner is the node itself
      # and not a name: two classes of one name in one file are one class, but
      # this only has to tell one BODY from another.
      def each_def_with_owner(node, owner = nil, &block)
        return unless node.is_a?(Parser::AST::Node)

        if node.type == :def || node.type == :defs
          yield node, owner
          # A `def` inside a `def` is still a method of the class around it.
          each_def_with_owner(body_of(node), owner, &block)
          return
        end

        inner = SCOPES.include?(node.type) ? node : owner
        node.children.each { |child| each_def_with_owner(child, inner, &block) }
      end

      # `{ owner node => { [singleton?, name] => summary } }` for this whole
      # source: what each method of each class body does to the arrays it is
      # handed. `nil` for a summary means the name is defined more than once
      # here, which is a name this cannot resolve to a body at all.
      def builders_in(node, owner = nil, table = {}.compare_by_identity)
        return table unless node.is_a?(Parser::AST::Node)

        if node.type == :def || node.type == :defs
          # Deliberately NOT descending: a `def` written inside another one does
          # not exist until the outer body runs, so a call to that name is not
          # this body.
          register_builder(table, owner, node)
          return table
        end

        inner = SCOPES.include?(node.type) ? node : owner
        node.children.each { |child| builders_in(child, inner, table) }
        table
      end

      def register_builder(table, owner, def_node)
        singleton = def_node.type == :defs
        key = [singleton, singleton ? def_node.children[1] : def_node.children[0]]
        methods = (table[owner] ||= {})

        # Two definitions of one name in one body: which of them runs where is
        # not this walk's to say, so neither answers.
        methods[key] = methods.key?(key) ? nil : appends_in(def_node)
      end

      # The summaries a body may call by name alone: the methods of the class it
      # is written in, of the same kind — an implicit-self send inside
      # `def self.x` names a singleton method, and inside `def x` an instance
      # one.
      def builders_for(builders, owner, def_node)
        methods = builders[owner] or return {}
        singleton = def_node.type == :defs

        methods.each_with_object({}) do |((kind, name), summary), found|
          found[name] = summary if kind == singleton && summary
        end
      end

      # What one body appends to each of its parameters, as a list the length of
      # the parameter list — `[nil, [element node, …]]` for a body that appends
      # to its second parameter and leaves the first alone — or nil for a body
      # that appends to none of them.
      #
      # The same straight line, and the same disqualifications, as a local born
      # here: the only difference is that a parameter arrives holding something
      # this cannot see, so what is read off the pushes is what the call ADDS
      # rather than everything the array holds.
      #
      # Summarised without any summaries in scope, so `fill` calling `fill2` is
      # a body this declines rather than one it chases.
      def appends_in(def_node)
        body = body_of(def_node) or return nil
        names = positionals_of(def_node) or return nil
        return nil if names.empty?

        found = names.to_h { |name| [name, []] } #: Hash[Symbol, Array[untyped]?]

        lines = statements(body)
        # `return parts` hands the array back, which is what a builder is for.
        # It is only the CALLER's problem, and only where the caller keeps the
        # value — where it does, the call is not a bare statement and no summary
        # is applied to it.
        returned = returned_local(lines.last)

        lines.each_with_index do |statement, index|
          next if index == lines.size - 1 && returned

          read(statement, found, {})
        end

        summary = names.map { |name| found[name]&.any? ? found[name] : nil }
        summary.any? ? summary : nil
      end

      # The required positional parameters, or nil for a signature a call site
      # cannot be lined up with by counting — an optional, a rest, a keyword or
      # a block all make the parameter an argument lands in a question of its
      # own.
      def positionals_of(def_node)
        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        return nil unless args.is_a?(Parser::AST::Node)
        return nil unless args.children.all? { |argument| argument.type == :arg }

        args.children.map { |argument| argument.children[0] }
      end

      # `{ name => [element node, …] }` where this statement is a call to a body
      # this walk has, handing it locals it only appends to.
      def builds_onto(statement, found, builders)
        return nil unless statement.is_a?(Parser::AST::Node)
        return nil unless statement.type == :send && statement.children[0].nil?

        summary = builders[statement.children[1]] or return nil

        arguments = statement.children.drop(2)
        return nil unless arguments.size == summary.size
        return nil if arguments.any? { |argument| argument.type == :splat || argument.type == :block_pass }

        built = {} #: Hash[Symbol, Array[untyped]]
        arguments.each_with_index do |argument, index|
          elements = summary[index] or next
          next unless argument.type == :lvar

          name = argument.children[0]
          next unless found[name]
          # One array in two parameters is two orders of appends, and nothing
          # here picks between them.
          return nil if built.key?(name)

          built[name] = elements
        end

        built.empty? ? nil : built
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
      def read(statement, found, builders)
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

        if (built = builds_onto(statement, found, builders))
          built.each { |name, elements| found[name] = found[name] + elements }
          # What the call does to the arrays it appends to is read; everything
          # ELSE it names is a mention like any other.
          statement.children.drop(2).each do |argument|
            next if argument.type == :lvar && built.key?(argument.children[0])

            strike(argument, found)
          end
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

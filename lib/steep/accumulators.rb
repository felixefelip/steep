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
  # Or born from a CALL that hands back a new array, whose contents the checker
  # computed — a `filter_map` it answered per element, a method's `parameters`:
  #
  #     defn = parameters.filter_map { |type, arg| arg if type == :req }
  #     defn << "&"
  #     defn.join(", ")      # "a, &"
  #
  # The call is only a shape here (`Built`); which calls hand back an array
  # nobody else holds is the checker's to say (`FRESH`), and one it cannot
  # vouch for leaves the local without contents.
  #
  # The straight line need not be the method's own. A local born in an arm, or
  # in a loop's body, and named nowhere outside that list of statements lives
  # its whole life in it — so that list is read the same way.
  #
  # One block is the exception, because both of those are answerable for it:
  #
  #     ["x", "y"].each { |piece| parts << piece }
  #
  # runs NOW, once per element, and the elements are written out. So a `Loop`
  # takes its place among the pushes and the checker expands it — once per
  # element of a collection whose length it knows, with the block parameter
  # bound to that element (`TypeConstruction#record_iterations`).
  #
  # And one conditional is the exception for the same reason, once the checker
  # has DECIDED it:
  #
  #     parts << "self.private" if private     # `private` is `nil` here
  #
  # pushes nothing on a call site that passes no `private:`, and the check of
  # the body knows that — it reported the arm unreachable. So a `Branch` takes
  # its place among the pushes, holding what each arm would push, and the
  # checker says which arm ran where it checks the `if`
  # (`TypeConstruction#record_arm`). A condition it leaves open leaves the local
  # without contents, which is what every conditional push did before. Inside a
  # loop the arm is decided once per pass, so `if method == :a` can push on one
  # element and not on the next.
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

    # The pushes one `each` makes on every pass, in the order it makes them.
    # The count is not here: it is the length of the collection, which the
    # checker knows and this walk may not — a constant or a parameter is a
    # collection only its type spells out.
    Loop = Struct.new(:block, :values)

    # The pushes under one `if`, arm by arm, in the order each arm makes them —
    # an `elsif` is a `Branch` of its own inside `else_values`. Which arm runs
    # is not here: it is a question about the condition's type, and the checker
    # answers it where it checks the `if`.
    Branch = Struct.new(:node, :then_values, :else_values)

    # What a parameter holds on entry: what the call handed it. A rest
    # parameter's array is BUILT by the call, so nothing but this body can reach
    # it — it is born here as surely as `parts = []` is, only with contents the
    # call site writes rather than the body. A required one holds the array a
    # caller handed on, and the caller vouched for it when it did (see
    # `handed_arguments`). Which contents they are is the checker's to say, from
    # the call this body is being checked for; checked for none, they have none.
    Arrived = Struct.new(:def_node, :name)

    # What a local born from a call holds: the array `node` evaluates to. Which
    # one it is the checker says, and only for a call in `FRESH`.
    Built = Struct.new(:node)

    # The calls whose array is new on every call and held by nothing else, so a
    # local born from one is as private as one born from `[]`. Keyed like the
    # intrinsic tables, by the method the call resolved to.
    FRESH = Set[
      "::Array#map", "::Array#collect", "::Enumerable#filter_map",
      "::Method#parameters", "::UnboundMethod#parameters"
    ].freeze

    # Block calls that hand each element to a body and leave the receiver as it
    # was — unless the body changes an element in place, which nothing here
    # follows. So one of these is the LAST thing that may read the local: a
    # mention after it takes the local away.
    BLOCK_READS = %i[map collect filter_map].freeze

    # Calls that answer with a value holding none of the receiver's elements.
    # `parameters.map(&:first)` shares the elements it picks; read by one of
    # these and dropped, nothing is left holding them.
    SCALAR_READS = %i[join size length empty? count include? intersect?].freeze

    # What can end a pass early, or end the loop: each one makes "one push per
    # element" a claim about the elements that ran, which is not all of them.
    JUMPS = %i[break next redo retry return].freeze

    # Writes of a value to a name other than a local's.
    ASSIGNMENTS = %i[ivasgn gvasgn cvasgn casgn].freeze

    # Loops whose condition and body both run once per turn.
    REPEATS = %i[while until while_post until_post].freeze

    class << self
      # `{ name => [element node, …] }` for every local in `def_node` whose
      # contents this can read, with the pushes in the order they happen.
      #
      # Only the body's STRAIGHT LINE is read: a statement of the method itself,
      # not one inside an `if`, a loop or a block. That is the whole soundness
      # argument and it is deliberately blunt —
      #
      #     fill = -> { parts << "b" }  # when, and how many times?
      #     while more?; parts << x; end  # once per turn, and nothing counts them
      #
      # — so a push this cannot count simply disqualifies the local. A loop whose
      # body is itself a straight line is the one block that is counted, and an
      # `if` whose arms are is the one conditional; both are only SHAPES here,
      # and the checker declines what it cannot count or decide. Every other
      # mention of the name disqualifies it too: `other = parts` and
      # `fill(parts)` both hand the array to someone who can push into it, and a
      # tracker that answered anyway would be confidently wrong rather than
      # vague.
      def in_body(def_node, builders)
        body = body_of(def_node) or return {}

        found = {} #: Hash[Symbol, Array[untyped]?]
        entry_params(def_node).each { |name| found[name] = [Arrived.new(def_node, name)] }
        handed = Set.new #: Set[Symbol]
        lines = statements(body)
        # The value a body ENDS on leaves it, and nothing in this body runs
        # afterwards to be told a lie about it. `parts` written last is the
        # array as it stands, which is exactly what the caller receives — so it
        # is read rather than struck, where `fill(parts)` in the middle is still
        # struck because what follows could read the array the callee changed.
        returned = returned_local(lines.last)

        lines.each_with_index do |statement, index|
          next if index == lines.size - 1 && returned

          read(statement, found, builders, handed)
        end

        # Handed back after being handed on: what leaves is what the callee
        # left in it.
        found[returned] = nil if returned && handed.include?(returned)

        found.reject { |_, pushes| pushes.nil? }
      end

      # The locals born in one nested list of statements — an arm, a loop's body
      # — that this can read, by the same straight-line rules as `in_body`. Only
      # a local named nowhere else in the method qualifies: its whole life is in
      # these statements, so nothing outside them can reach its array.
      #
      # Nothing arrives here and nothing leaves: a local written last is a value
      # handed to whatever the list is part of (`definition = if … else defn
      # end`), which is a second name for the array, and is struck like one.
      def in_lines(def_node, lines, builders)
        found = {} #: Hash[Symbol, Array[untyped]?]
        handed = Set.new #: Set[Symbol]
        lines.each { |statement| read(statement, found, builders, handed) }

        found.select { |name, pushes| pushes && local_to?(def_node, lines, name) }
      end

      # The method's own straight line, then every nested one in it. A `begin`
      # is the only node holding more than one statement, and a local has to be
      # born and read for a list to have anything to say.
      def each_line_list(def_node)
        body = body_of(def_node) or return

        yield statements(body), true

        each_node(body) do |node|
          yield node.children, false if node.type == :begin && !node.equal?(body)
        end
      end

      # Whether every mention of `name` in the method is in `lines`, and the
      # method takes no parameter of that name.
      def local_to?(def_node, lines, name)
        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        return false if args.is_a?(Parser::AST::Node) && args.children.any? { |arg| arg.children[0] == name }

        mentions_of(body_of(def_node), name) == lines.sum { |line| mentions_of(line, name) }
      end

      def mentions_of(node, name)
        count = 0
        each_node(node) do |child|
          count += 1 if (child.type == :lvar || child.type == :lvasgn) && child.children[0] == name
        end
        count
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
      #
      # `loops` — `{ block node => [value node or Branch, …] }`, every `each`
      # some local's contents run through, with what its body pushes. The
      # checker re-checks those bodies once per element, so this is where it
      # learns which ones.
      #
      # `branches` — `{ if node => true }`, every conditional some push sits
      # under, so the checker records the arm it decided only where someone
      # will ask for it.
      #
      # `at_args` — `{ lvar node => [element node, …] }`, a local handed to a
      # call as an argument, with what it holds as the call is made. The callee
      # reads it from its own parameter, so this is what that parameter arrives
      # holding.
      Analysis = Struct.new(:at_reads, :final, :returned, :loops, :branches, :at_args, keyword_init: true)

      # Every value node and every `Branch` in a list of pushes, however deeply
      # nested in arms. What a pass of a loop has to keep is exactly these.
      def each_entry(entries, &block)
        entries.each do |entry|
          yield entry

          case entry
          when Branch
            each_entry(entry.then_values, &block)
            each_entry(entry.else_values, &block)
          when Loop
            each_entry(entry.values, &block)
          end
        end
      end

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
        loops = {}.compare_by_identity #: Hash[untyped, Array[untyped]]
        branches = {}.compare_by_identity #: Hash[untyped, bool]
        at_args = {}.compare_by_identity #: Hash[untyped, Array[untyped]]

        builders = builders_in(node)

        each_def_with_owner(node) do |def_node, owner|
          each_returned(def_node) { |array| returned[array] = true }
          methods = builders_for(builders, owner, def_node)

          each_line_list(def_node) do |lines, top|
          last = {} #: Hash[Symbol, [untyped, Array[untyped]]]

          replay(def_node, lines, top, methods) do |statement, pushed, contents|
            # A loop over a local this vouches for READS it, and the checker asks
            # for the count of passes at the `each`. The loop cannot push onto
            # the local it runs over, so the contents are the same either side.
            if (over = looped_local(statement, contents))
              at_reads[statement.children[0]] = contents.fetch(over)
            end

            unless pushed.empty?
              pushed.each do |name|
                elements = contents.fetch(name)
                last[name] = [statement, elements]

                entry = elements.last
                case entry
                when Loop
                  next unless entry.block.equal?(statement)

                  (loops[entry.block] ||= []).concat(entry.values)
                when Branch
                  next unless entry.node.equal?(statement)
                else
                  next
                end

                each_entry([entry]) { |nested| branches[nested.node] = true if nested.is_a?(Branch) }
              end
              next
            end

            handed_arguments(statement, contents).each do |argument|
              at_args[argument] = contents.fetch(argument.children[0])
            end

            each_node(statement) do |child|
              next unless child.type == :send
              next unless READERS.include?(child.children[1]) || BLOCK_READS.include?(child.children[1])

              receiver = child.children[0]
              next unless receiver&.type == :lvar && contents.key?(receiver.children[0])

              at_reads[child] = contents.fetch(receiver.children[0])
            end
          end

          last.each do |name, (statement, elements)|
            (final[statement] ||= {})[name] = elements
          end
          end
        end

        Analysis.new(at_reads: at_reads, final: final, returned: returned, loops: loops, branches: branches, at_args: at_args)
      end

      # A value a local can be born from as a `Built`: a call, with or without
      # a block. Shared with `LocalAssignments`, whose pushed births are the
      # same locals seen from the type side.
      def built_call?(node)
        return false unless node.is_a?(Parser::AST::Node)

        node.type == :send || (node.type == :block && node.children[0].type == :send)
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
      def replay(def_node, lines, top, builders)
        readable = top ? in_body(def_node, builders) : in_lines(def_node, lines, builders)
        return if readable.empty?

        contents = {} #: Hash[Symbol, Array[untyped]]
        # Born on entry, before any statement runs.
        if top
          entry_params(def_node).each do |name|
            contents[name] = [Arrived.new(def_node, name)] if readable.key?(name)
          end
        end

        lines.each do |statement|
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
          elsif (counted = loop_onto(statement, contents) || branch_onto(statement, contents))
            entries, mentioned = counted
            entries.each do |name, entry|
              next if mentioned.include?(name)

              contents[name] = contents.fetch(name) + [entry]
              pushed << name
            end
          elsif (push = push_onto(statement, contents))
            name, values = push
            contents[name] = contents.fetch(name) + values
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

          # Strict: the CALLER reads the array after this body returns, so an
          # array handed on from here is one it cannot count.
          read(statement, found, {}, nil)
        end

        # A loop is expanded by the checker where the BLOCK is checked, and a
        # conditional decided where the `if` is — both in this body and not at
        # the call, so a caller has nothing to expand them with, and a summary
        # that left them out would miscount.
        return nil if found.each_value.any? { |pushes| pushes&.any? { |entry| entry.is_a?(Loop) || entry.is_a?(Branch) } }

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
      # literal, or from a call (`Built`) the checker may vouch for.
      def seed_from(statement)
        return nil unless statement.is_a?(Parser::AST::Node) && statement.type == :lvasgn

        name, value = statement.children
        return [name, value.children.dup] if array_literal?(value)
        return [name, [Built.new(value)]] if built_call?(value)

        nil
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
      def read(statement, found, builders, handed)
        return unless statement.is_a?(Parser::AST::Node)

        # Named again after it was handed on: what it holds now is whatever the
        # callee left in it.
        handed&.each do |name|
          found[name] = nil if found[name] && mentions?(statement, [name])
        end

        if (seed = seed_from(statement))
          name, elements = seed
          # What the value names is read like any other statement: a local an
          # element is taken from, or one handed to the call, is reachable
          # under the new name too.
          strike_held_element(statement.children[1], found)
          consume(statement.children[1], found, handed)
          # A second assignment is a different array, and nothing here orders
          # the two.
          found[name] = found.key?(name) ? nil : elements
          return
        end

        if (push = push_onto(statement, found))
          name, values = push
          found[name] = found[name] + values
          return
        end

        if (counted = loop_onto(statement, found) || branch_onto(statement, found))
          entries, mentioned = counted
          mentioned.each { |name| found[name] = nil if found.key?(name) }
          entries.each { |name, entry| found[name] = found[name] + [entry] if found[name] }
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

        # Handed to a call and named nowhere else in the statement. What it held
        # as the call was made is known, and is what the callee receives; only
        # what the callee does to it is not — so it stays readable for that
        # moment, and any later mention takes it away (above).
        if handed && (arguments = handed_arguments(statement, found)).any?
          names = arguments.map { |argument| argument.children[0] }
          kept = names.to_h { |name| [name, found[name]] }
          strike(statement, found)
          kept.each { |name, elements| found[name] = elements }
          handed.merge(names)
          return
        end

        consume(statement, found, handed)
      end

      # Strikes what `node` names, except a local whose block read in it is the
      # last thing that reads it (`last_reads`). That one stays readable for
      # this statement, and like a local handed on, any later mention takes it
      # away. Strict where there is no `handed` to say so: a builder's caller
      # reads the array after the body returns.
      def consume(node, found, handed)
        names = handed ? last_reads(node, found) : []
        kept = names.to_h { |name| [name, found[name]] }
        strike(node, found)
        kept.each { |name, elements| found[name] = elements }
        handed&.merge(names)
      end

      # The watched locals whose `map`/`collect`/`filter_map` with a block in
      # `node` is the last read of them there: run once, and every other mention
      # in `node` a `map(&:reader)` consumed by a scalar read, written before it
      # and outside any body of its own.
      #
      #     if parameters.map(&:first).intersect?([:opt, :rest])   # read
      #       "..."
      #     else
      #       defn = parameters.filter_map { |type, arg| … }       # last read
      #     end
      def last_reads(node, found)
        reads = [] #: Array[untyped]
        block_reads_in(node, found, reads)

        by_name = reads.group_by { |block| block.children[0].children[0].children[0] }
        by_name.filter_map do |name, blocks|
          next if blocks.size > 1

          block = blocks.first
          start = block.location.expression.begin_pos
          others = mention_nodes(node, name).reject { |mention| mention.equal?(block.children[0].children[0]) }
          next unless others.all? { |mention| mention.location.expression.end_pos <= start && mapped_read_of?(node, mention) }

          name
        end
      end

      # Block reads of watched locals made at most once each time `node` runs.
      def block_reads_in(node, found, reads)
        return unless node.is_a?(Parser::AST::Node)
        return if SCOPES.include?(node.type) || REPEATS.include?(node.type)

        if CLOSURES.include?(node.type)
          call = node.children[0]
          receiver = call.children[0] if call.type == :send
          if receiver&.type == :lvar && found[receiver.children[0]] &&
             BLOCK_READS.include?(call.children[1]) && call.children.size == 2 && node.type == :block
            reads << node
          end
          # The body runs on a schedule of its own.
          return block_reads_in(call, found, reads)
        end

        node.children.each { |child| block_reads_in(child, found, reads) }
      end

      def mention_nodes(node, name)
        mentions = [] #: Array[untyped]
        each_node(node) do |child|
          mentions << child if (child.type == :lvar || child.type == :lvasgn) && child.children[0] == name
        end
        mentions
      end

      # Whether `mention` is the receiver of a `map(&:reader)` that a scalar
      # read consumes, outside any closure or loop in `node`.
      def mapped_read_of?(node, mention, inside = false)
        return false unless node.is_a?(Parser::AST::Node)
        return false if SCOPES.include?(node.type)

        if !inside && node.type == :send && scalar_mapped_read?(node)
          return true if node.children[0].children[0].equal?(mention)
        end

        repeats = inside || CLOSURES.include?(node.type) || REPEATS.include?(node.type)
        node.children.any? { |child| mapped_read_of?(child, mention, repeats) }
      end

      # `local.map(&:first).intersect?(…)`: the elements `map` picks are shared
      # with the local, and the scalar read hands none of them on.
      def scalar_mapped_read?(node)
        node.type == :send && SCALAR_READS.include?(node.children[1]) && mapped_read?(node.children[0])
      end

      def mapped_read?(node)
        return false unless node.is_a?(Parser::AST::Node) && node.type == :send
        return false unless BLOCK_READS.include?(node.children[1]) && node.children.size == 3
        return false unless node.children[0]&.type == :lvar

        pass = node.children[2]
        pass.type == :block_pass && pass.children[0]&.type == :sym &&
          READERS.include?(pass.children[0].children[0])
      end

      # The locals this statement hands to a call as a direct argument —
      # positional or keyword — and names nowhere else. A second mention in the
      # same statement could change the array before the call or after it, in an
      # order nothing here follows.
      #
      # Only a call the statement makes ONCE hands anything on. One in a loop,
      # or in a block, runs any number of times, and the contents recorded here
      # are only what the first run receives — the callee may push onto the
      # array, and the next run receives that:
      #
      #     [1, 2].each { fill(parts) }   # `fill` gets `parts`, then `parts` + what it pushed
      def handed_arguments(statement, found)
        candidates = [] #: Array[untyped]

        each_call_once(statement) do |child|
          arguments = child.children.drop(2)
          if arguments.last&.type == :kwargs
            pairs = arguments.pop.children
            arguments.concat(pairs.filter_map { |pair| pair.children[1] if pair.type == :pair })
          end

          arguments.each do |argument|
            candidates << argument if argument.type == :lvar && found[argument.children[0]]
          end
        end

        candidates.select do |argument|
          name = argument.children[0]
          count = 0
          each_node(statement) do |child|
            count += 1 if (child.type == :lvar || child.type == :lvasgn) && child.children[0] == name
          end
          count == 1
        end
      end

      # Every `send` in `node` that runs at most once each time `node` does. A
      # loop's condition and body run once per turn, and a closure's body on a
      # schedule of its own — only the call a block is attached to is made where
      # it is written. A `retry` runs the whole statement again.
      def each_call_once(node, &block)
        return if jumps_back?(node)

        each_call_in(node, &block)
      end

      def each_call_in(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        return if SCOPES.include?(node.type) || REPEATS.include?(node.type)

        # `items.each { … }`: the call is made here, the body later.
        return each_call_in(node.children[0], &block) if CLOSURES.include?(node.type)
        # `for x in items`: the collection is read once, the body per item.
        return each_call_in(node.children[1], &block) if node.type == :for

        yield node if node.type == :send
        node.children.each { |child| each_call_in(child, &block) }
      end

      def jumps_back?(node)
        each_node(node) do |child|
          return true if child.type == :retry
        end

        false
      end

      # A read that hands back an ELEMENT of a local this walk is watching.
      def element_read?(node)
        node.is_a?(Parser::AST::Node) && node.type == :send &&
          CollectionReaders.element?(node) && node.children[0]&.type == :lvar
      end

      # `[name, [value, …]]` where this statement pushes onto a watched local.
      # More than one value for `parts << a << b`: `<<` hands back the array it
      # was called on, so each link of the chain pushes onto the same one.
      def push_onto(statement, found)
        values = [] #: Array[untyped]
        node = statement

        while node.is_a?(Parser::AST::Node) && node.type == :send && node.children[1] == :<< && node.children.size == 3
          values.unshift(node.children[2])
          node = node.children[0]
        end

        return nil if values.empty?
        return nil unless node&.type == :lvar

        name = node.children[0]
        return nil unless found[name]

        [name, values]
      end

      # `{ name => Loop }` where this statement is an `each` over a collection,
      # whose body pushes onto watched locals in a straight line of its own —
      # and mentions them nowhere else. Anything short of that is a closure like
      # any other, and `strike` takes every local it names.
      #
      # Only the shape is decided here. Whether the receiver is a collection of
      # known length, and that `each` is Array's own, are questions about types,
      # and the checker answers them where it expands the loop: one it cannot
      # expand leaves the local without contents rather than with wrong ones.
      def loop_onto(statement, found)
        return nil unless statement.is_a?(Parser::AST::Node) && statement.type == :block

        call, args, body = statement.children
        return nil unless call.type == :send && call.children[1] == :each && call.children.size == 2

        collection = call.children[0] or return nil
        param = block_param(args) or return nil

        watched = found.select { |_, pushes| pushes }.keys
        # Inside the block the parameter IS that name, so a push onto it is a
        # push onto the element.
        return nil if watched.include?(param)
        # The collection may be a local this vouches for — that is a READ, and
        # its contents are the count. Named any other way it is a mention.
        over = looped_local(statement, found)
        return nil if !over && mentions?(collection, watched)

        lines = statements(body)
        return nil if lines.empty?
        return nil if lines.any? { |line| jumps?(line) }

        pushes, mentioned = pushes_in(lines, found, watched)
        return nil if pushes.empty?
        # Pushing onto the array being run over: one more pass per push, which
        # is no count at all.
        return nil if over && pushes.key?(over)

        loops = pushes.reject { |name, _| mentioned.include?(name) }
        [loops.transform_values { |values| Loop.new(statement, values) }, mentioned]
      end

      # The name of the watched local an `each` statement runs over, or nil.
      def looped_local(statement, found)
        return nil unless statement.is_a?(Parser::AST::Node) && statement.type == :block

        call = statement.children[0]
        return nil unless call.type == :send && call.children[1] == :each && call.children.size == 2

        collection = call.children[0]
        return nil unless collection&.type == :lvar

        name = collection.children[0]
        found[name] ? name : nil
      end

      # The parameters of `def_node` that hold an array a call handed in: the
      # positional rest, every required positional and every required keyword.
      # An anonymous `*` has no local to read.
      def entry_params(def_node)
        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        return [] unless args.is_a?(Parser::AST::Node)

        args.children.filter_map do |arg|
          arg.children[0] if %i[restarg arg kwarg].include?(arg.type) && arg.children[0]
        end
      end

      # `[{ name => Branch }, mentioned]` where this statement is an `if` whose
      # arms push onto watched locals in a straight line of their own. Which arm
      # runs is the checker's to say; only the shape is decided here. A watched
      # local the condition or an arm names in any other way is `mentioned`,
      # and only that one is taken away.
      def branch_onto(statement, found)
        watched = found.select { |_, pushes| pushes }.keys
        branch_in(statement, found, watched)
      end

      def branch_in(statement, found, watched)
        return nil unless statement.is_a?(Parser::AST::Node) && statement.type == :if

        predicate, then_clause, else_clause = statement.children
        # An arm that may leave early pushes what it reached, which is not what
        # it says.
        return nil if jumps?(statement)

        mentioned = names_in(predicate, watched)
        arms = [then_clause, else_clause].map do |clause|
          pushes, inner = pushes_in(statements(clause), found, watched)
          mentioned.merge(inner)
          pushes
        end

        names = arms.flat_map(&:keys).uniq - mentioned.to_a
        return nil if names.empty?

        branches = names.to_h do |name|
          [name, Branch.new(statement, arms[0].fetch(name, []), arms[1].fetch(name, []))]
        end
        [branches, mentioned]
      end

      # `[{ name => [value node or Branch, …] }, mentioned]` for a straight line
      # of a body this walk reads but does not own — a loop's, or an arm's.
      # `mentioned` is every watched local one of its statements names in any
      # other way: that local cannot be counted, but the others still can, so
      # it alone is taken away. A loop inside the line is such a mention: its
      # passes would have to be expanded per pass of the outer body, which
      # nothing does.
      def pushes_in(lines, found, watched)
        pushes = {} #: Hash[Symbol, Array[untyped]]
        mentioned = Set.new #: Set[Symbol]

        lines.each do |line|
          if (push = push_onto(line, found))
            name, values = push
            values.each { |value| mentioned.merge(names_in(value, watched)) }

            (pushes[name] ||= []).concat(values)
          elsif (branched = branch_in(line, found, watched))
            branches, inner = branched
            mentioned.merge(inner)
            branches.each { |name, branch| (pushes[name] ||= []) << branch }
          else
            mentioned.merge(names_in(line, watched))
          end
        end

        [pushes, mentioned]
      end

      # The watched locals `node` reads or writes, stopping at a body of its own.
      def names_in(node, names)
        found = Set.new #: Set[Symbol]
        each_node(node) do |child|
          found << child.children[0] if (child.type == :lvar || child.type == :lvasgn) && names.include?(child.children[0])
        end
        found
      end

      # The one parameter of `{ |x| … }`, or nil for any other list — two
      # parameters destructure the element, which is a different question.
      def block_param(args)
        return nil unless args.is_a?(Parser::AST::Node) && args.type == :args && args.children.size == 1

        param = args.children[0]
        param = param.children[0] if param.type == :procarg0 && param.children.size == 1 && param.children[0].is_a?(Parser::AST::Node)

        case param.type
        when :arg
          param.children[0]
        when :procarg0
          param.children[0].is_a?(Symbol) ? param.children[0] : nil
        end
      end

      # Whether `node` reads or writes one of `names`, stopping at a body of its
      # own.
      def mentions?(node, names)
        each_node(node) do |child|
          return true if (child.type == :lvar || child.type == :lvasgn) && names.include?(child.children[0])
        end

        false
      end

      def jumps?(node)
        each_node(node) do |child|
          return true if JUMPS.include?(child.type)
        end

        false
      end

      def array_literal?(node)
        node.is_a?(Parser::AST::Node) && node.type == :array &&
          node.children.none? { |child| child.type == :splat }
      end

      # An element read whose answer is KEPT under another name: that name can
      # change the element in place, as a call on the answer can.
      #
      #     y = parts.first
      #     y << "b"              # parts is ["ab"] from here on
      def strike_held_element(value, found)
        return unless element_read?(value)

        name = value.children[0].children[0]
        found[name] = nil if found.key?(name)
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
          strike_held_element(node.children[1], found)
          strike(node.children[1], found, closure: closure)
          return
        end

        if ASSIGNMENTS.include?(node.type)
          strike_held_element(node.children.last, found)
        end

        if !closure && scalar_mapped_read?(node)
          node.children.drop(2).each do |argument|
            next if CollectionReaders.binary?(node) && argument.type == :lvar

            strike(argument, found, closure: closure)
          end
          return
        end

        if !closure && node.type == :send && CollectionReaders.read?(node) && node.children[0]&.type == :lvar
          node.children.drop(2).each do |argument|
            # The other side of a `+` is read, not handed anywhere.
            next if CollectionReaders.binary?(node) && argument.type == :lvar

            strike(argument, found, closure: closure)
          end
          return
        end

        # A call ON the answer of one of those. `parts.first` hands back an
        # ELEMENT, and the next call is free to change it in place:
        #
        #     parts.first << "b"    # parts is ["ab"] from here on
        #
        # The read itself is still a read; what takes the local away is that
        # something else is holding one of its elements.
        if node.type == :send && element_read?(node.children[0])
          strike(node.children[0].children[0], found, closure: closure)
          node.children.drop(1).each { |child| strike(child, found, closure: closure) }
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

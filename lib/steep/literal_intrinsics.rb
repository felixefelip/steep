module Steep
  # Exact return types for a deliberately small set of Ruby core operations on
  # literal values. This is not general constant evaluation: dispatch has
  # already succeeded against RBS, every operand must be a literal, the method
  # must resolve to one closed-table core identity, and any project override
  # disables the entry.
  #
  # An operand is either a literal or a TUPLE of them, so a call whose receiver
  # or argument is an array written out in the source folds as well. Nothing
  # else about arrays is modelled: an array assembled by `<<`, or one whose
  # elements are not all literal, has no tuple to read and declines here.
  module LiteralIntrinsics
    MAX_LITERAL_WIDTH = 64
    MAX_INTEGER_BITS = 256

    # How many elements an operand may hold. A bound on the work, not on the
    # text: the widths below are what keep the result small.
    MAX_COLLECTION_SIZE = 64

    # A whole collection operand may be wider than a single literal, because its
    # bytes are already written in the file. Still bounded, so a pathological
    # source cannot make the checker assemble an unbounded string.
    MAX_OPERAND_WIDTH = 4096

    # How long one match may run, in seconds. The subject is held to a single
    # literal's width, but a pattern written to backtrack does not need a long
    # subject to take forever, and this one runs inside the checker.
    REGEXP_TIMEOUT = 0.05

    # `depends_on` names the methods a fold LEANS on without owning: `join`
    # owns nothing beyond itself, but `include?` answers by calling `==` on the
    # elements and `intersect?` by calling `eql?`/`hash`. A project that
    # redefines one of those makes the value computed in this process disagree
    # with the value the program computes, and the entry's own key says nothing
    # about it — so the entry declares them and they are checked alongside it.
    #
    # `module_function` marks a method whose answer does not depend on the
    # receiver, so a call folds whatever `self` is.
    #
    # `native` answers in place of calling `method`, for a core method that is
    # Ruby in some versions and C in others. The provenance check below refuses
    # a method written in Ruby, because this process cannot claim to model it —
    # and `Set` is `set.rb` until Ruby 3.5, so on 3.4 `Set#include?` never
    # folded and `RESERVED_METHOD_NAMES.include?(receiver)` in
    # `ActiveSupport::Delegation.generate` was never decided. What the method
    # IS does not change between the two: membership by `hash`/`eql?`, which
    # `native` computes with `Hash#key?` on the same elements, under the same
    # preflight and the same `depends_on`.
    Entry = _ = Struct.new(:method, :arity, :preflight, :depends_on, :native, :module_function, keyword_init: true)

    # The element classes a dispatching fold is allowed to see. Not a
    # convenience: `depends_on` has to be a FINITE list, and it can only be
    # finite if the elements are confined to classes the registry already reads
    # reopens of (`LiteralMethodRegistry::CORE_CLASSES`). `true`/`false` are out
    # for the same reason — `TrueClass` is not one of those.
    COMPARABLE_ELEMENTS = [::String, ::Symbol, ::Integer].freeze
    EQUALITY_METHODS = %w[::String#== ::Symbol#== ::Integer#==].freeze
    HASH_METHODS = %w[::String#eql? ::Symbol#eql? ::Integer#eql? ::String#hash ::Symbol#hash ::Integer#hash].freeze

    # What `join` asks a Symbol element before it renders it. It is not a
    # String, so `join` first probes for `to_str` and `to_ary` — and a probe
    # consults `respond_to?`, `respond_to_missing?` and `method_missing` where
    # the method is missing — and only then calls `to_s`. Each was measured:
    #
    #   class Symbol; def to_str = "T"; end   #=> [:a].join(",") == "T"
    #   class Symbol; def to_ary = ["x", "y"]; end  #=> "x,y"
    #
    # The probes find the method anywhere in Symbol's chain, which is finite.
    SYMBOL_JOIN_METHODS = (
      ["::Symbol#to_s"] +
      %w[Symbol Comparable Object Kernel BasicObject].product(
        %w[to_str to_ary respond_to? respond_to_missing? method_missing]
      ).map { |owner, name| "::#{owner}##{name}" }
    ).freeze

    # What `flatten` asks an element that is not an Array before it keeps it
    # as it is: whether it converts with `to_ary`, through the same probes
    # `join` makes. Elements are confined to strings and symbols, whose chains
    # the registry watches.
    FLATTEN_LEAVES = [::String, ::Symbol].freeze
    FLATTEN_METHODS = (
      %w[String Symbol Comparable Object Kernel BasicObject].product(
        %w[to_ary respond_to? respond_to_missing? method_missing]
      ).map { |owner, name| "::#{owner}##{name}" }
    ).freeze

    # What `Kernel#Array` asks an argument that is not an Array: `to_ary`, then
    # `to_a`, through the same probes `join` makes. An Array is answered as it
    # is, without a call.
    ARRAY_CONVERSION_LEAVES = [::String, ::Symbol, ::NilClass].freeze
    ARRAY_CONVERSION_METHODS = (
      %w[String Symbol NilClass Comparable Object Kernel BasicObject].product(
        %w[to_ary to_a respond_to? respond_to_missing? method_missing]
      ).map { |owner, name| "::#{owner}##{name}" }
    ).freeze

    # The modules a call made on the module itself folds for, with the object
    # the call is made on. Each entry below that names one is a module
    # function of it.
    MODULE_RECEIVERS = { "::Regexp" => ::Regexp }.freeze

    class << self
      # An operand that is a union of literals is each of them in turn: the call
      # folds once per combination of alternatives, and is the union of the
      # results, or declines when any one of them does.
      def fold(call:, receiver_type:, argument_types:, override_registry:)
        key = MethodIdentity.key(call) or return nil

        receivers, *arguments = [receiver_type, *argument_types].map { |type| alternatives(type) }
        results = receivers.product(*arguments).map do |receiver, *values|
          fold_key(key: key, receiver_type: receiver, argument_types: values, override_registry: override_registry) or return nil
        end
        AST::Types::Union.build(types: results)
      end

      # A value an accumulated array may hold: a literal, `nil`, or an array of
      # those.
      def fold_value?(type)
        case type
        when AST::Types::Literal, AST::Types::Nil then true
        when AST::Types::Tuple then type.types.all? { |element| fold_value?(element) }
        else false
        end
      end

      def literal_union?(type)
        type.is_a?(AST::Types::Union) && type.types.all?(AST::Types::Literal)
      end

      # The values `type` may be, one type each: a tuple holding a union is one
      # tuple per choice of its elements.
      def alternatives(type)
        case type
        when AST::Types::Union then type.types.flat_map { |member| alternatives(member) }
        when AST::Types::Tuple
          choices = type.types.map { |element| alternatives(element) }
          return [type] if choices.empty?

          choices.first.product(*choices.drop(1)).map { |elements| AST::Types::Tuple.new(types: elements) }
        else [type]
        end
      end

      # `fold` for a method already known by its key: an in-place one
      # (`StringMutation::IN_PLACE`), whose call was dispatched against the
      # widened receiver and so never reached `fold` with its literal.
      def fold_key(key:, receiver_type:, argument_types:, override_registry:)
        entry = ENTRIES[key] or return nil
        return nil unless entry.module_function || operand?(receiver_type)
        return nil unless argument_types.all? { |type| operand?(type) }

        return nil if override_registry.blocked?(key)
        return nil if entry.depends_on&.any? { |dependency| override_registry.blocked?(dependency) }
        source_location = entry.method.source_location
        return nil if source_location && !source_location.first.start_with?("<internal:") && !entry.native
        return nil unless entry.arity === argument_types.size

        receiver = operand_value(receiver_type) unless entry.module_function
        arguments = argument_types.map { |type| operand_value(type) }
        return nil unless within_input_budget?(receiver, arguments)
        return nil unless entry.preflight.call(receiver, arguments)

        value = entry.native ? entry.native.call(receiver, arguments) : entry.method.bind(receiver).call(*arguments)
        type = folded_type(value) or return nil
        # Measured the way the operands are. The type's printed form is not that
        # measure: `Set{…}` spells three bytes its elements do not, so a set
        # reassembled from a long enough array came out over the budget its own
        # elements set — `RESERVED_METHOD_NAMES`'s `to_set` declined.
        return nil if operand_width(value) > result_budget(receiver, arguments)

        type
      rescue ArgumentError, EncodingError, RangeError, ZeroDivisionError, Regexp::TimeoutError => exn
        Steep.logger.debug do
          "[literal_intrinsics] declined #{key}: #{exn.class}: #{exn.message}"
        end
        nil
      rescue StandardError => exn
        # Folding is optional, so an evaluator bug must not take down type
        # checking. Unlike expected runtime failures above, it must be visible.
        Steep.logger.warn do
          "[literal_intrinsics] unexpected failure for #{key}: #{exn.class}: #{exn.message}"
        end
        Steep.logger.debug { exn.full_message(highlight: false) }
        nil
      end

      # Every method key whose redefinition matters: the table's own, plus the
      # ones entries LEAN on. A reopen is recorded only for a key in here, so a
      # dependency nothing watches is a dependency that cannot be checked — and
      # `depends_on` would be a comment rather than a guard.
      def watched_keys
        @watched_keys ||= Set.new(
          ENTRIES.keys + ENTRIES.each_value.flat_map { |entry| entry.depends_on || [] }
        )
      end

      def method_keys_for(class_name)
        watched_keys.select { |key| key.start_with?("::#{class_name}#", "::#{class_name}.") }
      end

      private

      # A literal, or a tuple of things that are themselves operands. Nested
      # because a tuple of tuples is what a method's parameter list looks like,
      # and there is nothing to gain by refusing one depth.
      def operand?(type)
        case type
        when AST::Types::Literal, AST::Types::RegexpLiteral, AST::Types::RangeLiteral, AST::Types::Nil then true
        when AST::Types::Name::Singleton then MODULE_RECEIVERS.key?(type.name.to_s)
        when AST::Types::Tuple, AST::Types::FiniteSet then type.types.all? { |element| operand?(element) }
        else false
        end
      end

      def operand_value(type)
        case type
        when AST::Types::Tuple then type.types.map { |element| operand_value(element) }
        when AST::Types::FiniteSet then ::Set.new(type.types.map { |element| operand_value(element) })
        # Rebuilt rather than handed over, so the match runs under a timeout.
        when AST::Types::RegexpLiteral then ::Regexp.new(type.value.source, type.value.options, timeout: REGEXP_TIMEOUT)
        when AST::Types::RangeLiteral then type.value
        when AST::Types::Name::Singleton then MODULE_RECEIVERS.fetch(type.name.to_s)
        when AST::Types::Nil then nil
        else type.value
        end
      end

      # The type a folded VALUE is, or nil for one this does not carry. A
      # collection answers as the type that names its contents — which is the
      # only way an entry can return one at all, since every type here has to be
      # something the checker can go on to ask questions about.
      def folded_type(value)
        case value
        when ::Array
          types = value.map { |element| folded_type(element) }
          AST::Types::Tuple.new(types: types) if types.all?
        when ::Set
          types = value.map { |element| folded_type(element) }
          AST::Types::FiniteSet.new(types: types) if types.all?
        # `=~` that finds nothing. Exact, and what decides the `if` it is
        # written in.
        when nil
          AST::Types::Nil.instance
        when ::Regexp
          AST::Types::RegexpLiteral.new(value: value)
        else
          AST::Types::Literal.new(value: value) if literal_value?(value)
        end
      end

      def within_input_budget?(receiver, arguments)
        [receiver, *arguments].all? do |value|
          next false if collection_size(value) > MAX_COLLECTION_SIZE

          operand_width(value) <= (written_out?(value) ? MAX_OPERAND_WIDTH : MAX_LITERAL_WIDTH)
        end
      end

      def collection?(value)
        value.is_a?(::Array) || value.is_a?(::Set)
      end

      # An operand whose bytes are the file's own, so it may be wider than one
      # literal: a collection, or a pattern — whose cost is bounded by the
      # timeout and the subject's width, not by its own length.
      def written_out?(value)
        collection?(value) || value.is_a?(::Regexp)
      end

      # How wide the result may be. A fold that only reassembles its operands —
      # `join`, `first`, `+` — cannot outgrow them, so bytes already written in
      # the file are always affordable; `'x' * 1000` and `2 ** 4096` COMPUTE
      # theirs out of tiny operands and stay bounded by MAX_LITERAL_WIDTH. The
      # rule falls out of the operands and needs no per-entry taxonomy.
      def result_budget(receiver, arguments)
        [MAX_LITERAL_WIDTH, operand_width(receiver) + operand_width(arguments)].max
      end

      def operand_width(value)
        return value.inspect.bytesize unless collection?(value)

        value.sum { |element| operand_width(element) + 2 }
      end

      def collection_size(value)
        collection?(value) ? value.size : 0
      end

      def literal_value?(value)
        value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Symbol) || value == true || value == false
      end
    end

    ALWAYS = ->(_receiver, _arguments) { true }
    STRING_CONCAT = lambda do |receiver, arguments|
      other = arguments.first
      other.is_a?(String) && receiver.bytesize + other.bytesize <= MAX_LITERAL_WIDTH
    end
    STRING_REPEAT = lambda do |receiver, arguments|
      amount = arguments.first
      amount.is_a?(Integer) && amount >= 0 && amount <= MAX_LITERAL_WIDTH &&
        receiver.bytesize * amount <= MAX_LITERAL_WIDTH
    end
    # A pattern read without a call — a regexp, or a string, which `sub` takes
    # literally (`"abc".sub(".", "")` is "abc") — and a replacement STRING. A
    # hash replacement is looked up with `[]`, and a block is not a value;
    # neither is folded. `\1` in the replacement is read by `sub` itself.
    STRING_SUB = lambda do |_receiver, arguments|
      pattern, replacement = arguments
      (pattern.is_a?(::Regexp) || pattern.is_a?(String)) && replacement.is_a?(String)
    end
    # On a copy: the operand is the literal type's own value. What it answers
    # is what the program's call does — the changed string, or nil where
    # nothing was substituted — with no second question to disagree with it.
    STRING_SUB_BANG = ->(receiver, arguments) { receiver.dup.sub!(*arguments) }
    STRING_AFFIX = ->(_receiver, arguments) { arguments.first.is_a?(String) }
    ARRAY_FLATTEN = lambda do |receiver, arguments|
      leaves = ->(value) { value.is_a?(::Array) ? value.all?(&leaves) : FLATTEN_LEAVES.any? { |klass| value.is_a?(klass) } }
      (arguments.empty? || (arguments.size == 1 && arguments.first.is_a?(Integer))) && receiver.all?(&leaves)
    end
    # Two strings compare their bytes in C. Anything else on the right is
    # asked through its own `to_str`/`==`, which is another call.
    STRING_EQUAL = ->(_receiver, arguments) { arguments.first.is_a?(String) }
    # A slice by position: an index, a start and a length, or a range of
    # integers. A string or a regexp argument searches, which is another call.
    STRING_SLICE = lambda do |_receiver, arguments|
      arguments.all?(Integer) || (arguments.size == 1 && arguments.first.is_a?(::Range))
    end
    # On a copy, as `sub!`: what an in-place method answers, and leaves in the
    # array it runs on (`ArrayMutation::IN_PLACE`, `Accumulators::RESHAPES`).
    ARRAY_IN_PLACE = ->(method_name) { ->(receiver, arguments) { receiver.dup.public_send(method_name, *arguments) } }
    INTEGER_BINARY = ->(_receiver, arguments) { arguments.first.is_a?(Integer) }
    INTEGER_DIVISION = lambda do |_receiver, arguments|
      divisor = arguments.first
      divisor.is_a?(Integer) && !divisor.zero?
    end
    # `join` is a closed operation only over STRING elements with an explicit
    # separator, and both halves are load-bearing. A non-String element is
    # rendered by its own `to_s`, and a program that redefines one diverges from
    # the value folded in the checker's process: with `Integer#to_s` replaced,
    # `[1, 2].join(",")` runs as `"hijacked,hijacked"`. Omitting the separator
    # reads `$,`, a global this cannot see. With neither, `join` walks its
    # elements and concatenates them — no dispatch, nothing global.
    #
    # Symbols are the one exception, because what they dispatch to is a list
    # the registry can watch (`SYMBOL_JOIN_METHODS`). `parameters` names are
    # symbols, and `defn.join(", ")` over them is how ActiveSupport writes a
    # parameter list.
    ARRAY_JOIN = lambda do |receiver, arguments|
      arguments.size == 1 && arguments.first.is_a?(String) &&
        receiver.all? { |element| element.is_a?(String) || element.is_a?(Symbol) }
    end
    # `include?` and `intersect?` compare their operands, and comparison is a
    # CALL. Confining both sides to the classes above is what makes the list of
    # methods that call reaches finite, and therefore watchable.
    COMPARABLE = ->(value) { COMPARABLE_ELEMENTS.any? { |klass| value.is_a?(klass) } }
    # `+` walks its two operands and copies them; nothing is compared, nothing
    # is dispatched.
    ARRAY_CONCAT = ->(_receiver, arguments) { arguments.size == 1 && arguments.first.is_a?(::Array) }
    # `uniq` and `-` tell elements apart by `hash`/`eql?`; `compact` only
    # asks which ones are `nil`, in C.
    ARRAY_UNIQ = ->(receiver, arguments) { arguments.empty? && receiver.all?(&COMPARABLE) }
    ARRAY_DIFFERENCE = lambda do |receiver, arguments|
      other = arguments.first
      arguments.size == 1 && other.is_a?(::Array) && receiver.all?(&COMPARABLE) && other.all?(&COMPARABLE)
    end
    # `to_set` and `Set#include?` both answer through `hash`/`eql?`, so both
    # confine their elements to the classes those can be watched on.
    SET_BUILD = ->(receiver, arguments) { arguments.empty? && receiver.all?(&COMPARABLE) }
    SET_INCLUDE = lambda do |receiver, arguments|
      arguments.size == 1 && COMPARABLE[arguments.first] && receiver.all?(&COMPARABLE)
    end
    SET_MEMBER = lambda do |receiver, arguments|
      receiver.to_a.to_h { |element| [element, true] }.key?(arguments.first)
    end
    FREEZE = ->(_receiver, arguments) { arguments.empty? }
    KERNEL_ARRAY = lambda do |_receiver, arguments|
      argument = arguments.first
      arguments.size == 1 && (argument.is_a?(::Array) || ARRAY_CONVERSION_LEAVES.any? { |klass| argument.is_a?(klass) })
    end
    ARRAY_INCLUDE = lambda do |receiver, arguments|
      arguments.size == 1 && COMPARABLE[arguments.first] && receiver.all?(&COMPARABLE)
    end
    ARRAY_INTERSECT = lambda do |receiver, arguments|
      other = arguments.first
      arguments.size == 1 && other.is_a?(::Array) &&
        receiver.all?(&COMPARABLE) && other.all?(&COMPARABLE)
    end
    # A pattern matched against a string or a symbol, which `Regexp` reads
    # without calling anything — a symbol is taken as its name in C, not
    # through `to_s`. Anything else is converted by a call, and declines.
    SUBJECT = ->(value) { value.is_a?(String) || value.is_a?(Symbol) }
    REGEXP_MATCH = lambda do |_receiver, arguments|
      subject, position = arguments
      SUBJECT[subject] && (arguments.size == 1 || position.is_a?(Integer))
    end
    REGEXP_TILDE = ->(_receiver, arguments) { SUBJECT[arguments.first] }
    # The same question asked from the other side. A string pattern is
    # COMPILED, not quoted — `"abc".match?(".")` is true — and that too happens
    # without a call.
    SUBJECT_MATCH = lambda do |_receiver, arguments|
      pattern, position = arguments
      (pattern.is_a?(::Regexp) || pattern.is_a?(String)) && (arguments.size == 1 || position.is_a?(Integer))
    end
    # `String#=~` hands anything but a `Regexp` to the argument's own `=~`.
    SUBJECT_TILDE = ->(_receiver, arguments) { arguments.first.is_a?(::Regexp) }
    INTEGER_POWER = lambda do |receiver, arguments|
      exponent = arguments.first
      next false unless exponent.is_a?(Integer) && exponent >= 0

      base = receiver.abs
      next true if base <= 1
      next false if exponent > MAX_INTEGER_BITS

      base.bit_length * exponent <= MAX_INTEGER_BITS
    end

    ENTRIES = {
      "::String#upcase" => Entry.new(method: String.instance_method(:upcase), arity: 0, preflight: ALWAYS),
      "::String#downcase" => Entry.new(method: String.instance_method(:downcase), arity: 0, preflight: ALWAYS),
      "::String#capitalize" => Entry.new(method: String.instance_method(:capitalize), arity: 0, preflight: ALWAYS),
      "::String#reverse" => Entry.new(method: String.instance_method(:reverse), arity: 0, preflight: ALWAYS),
      "::String#strip" => Entry.new(method: String.instance_method(:strip), arity: 0, preflight: ALWAYS),
      "::String#+" => Entry.new(method: String.instance_method(:+), arity: 1, preflight: STRING_CONCAT),
      "::String#*" => Entry.new(method: String.instance_method(:*), arity: 1, preflight: STRING_REPEAT),
      "::String#length" => Entry.new(method: String.instance_method(:length), arity: 0, preflight: ALWAYS),
      "::String#empty?" => Entry.new(method: String.instance_method(:empty?), arity: 0, preflight: ALWAYS),
      "::String#to_sym" => Entry.new(method: String.instance_method(:to_sym), arity: 0, preflight: ALWAYS),
      # What an inflector rule is applied with (felixefelip/steep#209). What
      # `sub!` answers is also what its receiver holds after it, unless nil:
      # see `StringMutation::IN_PLACE`.
      "::String#sub" => Entry.new(method: String.instance_method(:sub), arity: 2, preflight: STRING_SUB),
      "::String#sub!" => Entry.new(
        method: String.instance_method(:sub!), arity: 2, preflight: STRING_SUB, native: STRING_SUB_BANG
      ),
      # `Inflections#irregular` keys its branch on `s0.upcase == p0.upcase`.
      "::String#==" => Entry.new(method: String.instance_method(:==), arity: 1, preflight: STRING_EQUAL),
      "::String#[]" => Entry.new(method: String.instance_method(:[]), arity: 1..2, preflight: STRING_SLICE),
      "::Array#flatten" => Entry.new(method: Array.instance_method(:flatten), arity: 0..1, preflight: ARRAY_FLATTEN, depends_on: FLATTEN_METHODS),
      # `Inflections::Uncountables#to_regex`.
      "::Regexp.escape" => Entry.new(method: ::Regexp.singleton_class.instance_method(:escape), arity: 1, preflight: STRING_AFFIX),
      "::String#delete_suffix" => Entry.new(method: String.instance_method(:delete_suffix), arity: 1, preflight: STRING_AFFIX),
      "::Array#prepend" => Entry.new(method: Array.instance_method(:prepend), arity: 0.., preflight: ALWAYS, native: ARRAY_IN_PLACE.(:prepend)),
      "::Array#unshift" => Entry.new(method: Array.instance_method(:unshift), arity: 0.., preflight: ALWAYS, native: ARRAY_IN_PLACE.(:unshift)),
      "::Array#push" => Entry.new(method: Array.instance_method(:push), arity: 0.., preflight: ALWAYS, native: ARRAY_IN_PLACE.(:push)),
      "::Array#<<" => Entry.new(method: Array.instance_method(:<<), arity: 1, preflight: ALWAYS, native: ARRAY_IN_PLACE.(:<<)),
      # A String literal is a `String` itself, never a subclass, so `to_s` is
      # the receiver unchanged. `Delegation.generate` writes it once the name
      # is already a string — `method_name.to_s` under `prefix:`.
      "::String#to_s" => Entry.new(method: String.instance_method(:to_s), arity: 0, preflight: ALWAYS),
      "::Integer#+" => Entry.new(method: Integer.instance_method(:+), arity: 1, preflight: INTEGER_BINARY),
      "::Integer#-" => Entry.new(method: Integer.instance_method(:-), arity: 1, preflight: INTEGER_BINARY),
      "::Integer#*" => Entry.new(method: Integer.instance_method(:*), arity: 1, preflight: INTEGER_BINARY),
      "::Integer#/" => Entry.new(method: Integer.instance_method(:/), arity: 1, preflight: INTEGER_DIVISION),
      "::Integer#%" => Entry.new(method: Integer.instance_method(:%), arity: 1, preflight: INTEGER_DIVISION),
      "::Integer#**" => Entry.new(method: Integer.instance_method(:**), arity: 1, preflight: INTEGER_POWER),
      "::Integer#abs" => Entry.new(method: Integer.instance_method(:abs), arity: 0, preflight: ALWAYS),
      "::Integer#succ" => Entry.new(method: Integer.instance_method(:succ), arity: 0, preflight: ALWAYS),
      "::Integer#to_s" => Entry.new(method: Integer.instance_method(:to_s), arity: 0, preflight: ALWAYS),
      "::Symbol#to_s" => Entry.new(method: Symbol.instance_method(:to_s), arity: 0, preflight: ALWAYS),
      # `match?` and not `match`: a `MatchData` is not a value a type holds.
      # `=~` folds where it is a call, which is when the pattern is on the
      # RIGHT or is not written out there: Ruby parses `/re/ =~ s` as a match
      # that may assign locals, a node of its own that this table never sees.
      "::Regexp#match?" => Entry.new(method: ::Regexp.instance_method(:match?), arity: 1..2, preflight: REGEXP_MATCH),
      "::Regexp#=~" => Entry.new(method: ::Regexp.instance_method(:=~), arity: 1, preflight: REGEXP_TILDE),
      "::String#match?" => Entry.new(method: String.instance_method(:match?), arity: 1..2, preflight: SUBJECT_MATCH),
      "::String#=~" => Entry.new(method: String.instance_method(:=~), arity: 1, preflight: SUBJECT_TILDE),
      "::Symbol#match?" => Entry.new(method: Symbol.instance_method(:match?), arity: 1..2, preflight: SUBJECT_MATCH),
      "::Symbol#=~" => Entry.new(method: Symbol.instance_method(:=~), arity: 1, preflight: SUBJECT_TILDE),
      # `::Array#first` is deliberately NOT here, though it folds as safely as
      # these do. `[1].first` is how a good deal of code — the checker's own
      # tests included — asks for an `Integer?`, and sharpening it to `1` turns
      # the `return unless a` that follows into an unreachable branch. The fold
      # is right and the change is real, so it belongs in the stage that has a
      # use for it (`parameters.map(&:first)`, S2/S3 of #171) and can carry the
      # test edits it forces, not in the one that needs `join`.
      "::Array#join" => Entry.new(
        method: Array.instance_method(:join), arity: 1, preflight: ARRAY_JOIN,
        depends_on: SYMBOL_JOIN_METHODS
      ),
      "::Array#include?" => Entry.new(
        method: Array.instance_method(:include?), arity: 1, preflight: ARRAY_INCLUDE,
        depends_on: EQUALITY_METHODS
      ),
      "::Array#intersect?" => Entry.new(
        method: Array.instance_method(:intersect?), arity: 1, preflight: ARRAY_INTERSECT,
        depends_on: EQUALITY_METHODS + HASH_METHODS
      ),
      "::Array#+" => Entry.new(method: Array.instance_method(:+), arity: 1, preflight: ARRAY_CONCAT),
      "::Array#uniq" => Entry.new(method: Array.instance_method(:uniq), arity: 0, preflight: ARRAY_UNIQ, depends_on: HASH_METHODS),
      "::Array#-" => Entry.new(method: Array.instance_method(:-), arity: 1, preflight: ARRAY_DIFFERENCE, depends_on: HASH_METHODS),
      "::Array#compact" => Entry.new(method: Array.instance_method(:compact), arity: 0, preflight: ALWAYS),
      "::Array#uniq!" => Entry.new(method: Array.instance_method(:uniq!), arity: 0, preflight: ARRAY_UNIQ, depends_on: HASH_METHODS, native: ARRAY_IN_PLACE.(:uniq!)),
      "::Array#compact!" => Entry.new(method: Array.instance_method(:compact!), arity: 0, preflight: ALWAYS, native: ARRAY_IN_PLACE.(:compact!)),
      # `freeze` answers the receiver, which is what makes it worth an entry: a
      # collection constant is written `[…].freeze`, and without this the fold
      # stops one call short of the value it just built.
      "::Array#freeze" => Entry.new(method: Array.instance_method(:freeze), arity: 0, preflight: FREEZE),
      # `Enumerable`'s, not `Array`'s — the table is keyed by what the call
      # RESOLVED to, and `to_set` is declared where every collection gets it.
      "::Enumerable#to_set" => Entry.new(
        method: Enumerable.instance_method(:to_set), arity: 0, preflight: SET_BUILD,
        depends_on: HASH_METHODS
      ),
      # `Kernel`'s, because that is where a `Set` resolves its `freeze` — and
      # from there it answers for a literal as readily as for a collection,
      # which is right: `freeze` hands back exactly what it was given.
      "::Kernel#freeze" => Entry.new(method: ::Kernel.instance_method(:freeze), arity: 0, preflight: FREEZE),
      "::Kernel#Array" => Entry.new(
        method: ::Kernel.instance_method(:Array), arity: 1, preflight: KERNEL_ARRAY,
        depends_on: ARRAY_CONVERSION_METHODS, module_function: true
      ),
      "::Set#include?" => Entry.new(
        method: ::Set.instance_method(:include?), arity: 1, preflight: SET_INCLUDE,
        depends_on: EQUALITY_METHODS + HASH_METHODS, native: SET_MEMBER
      )
    }.freeze
  end
end

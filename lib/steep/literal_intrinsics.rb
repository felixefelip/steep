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

    # `depends_on` names the methods a fold LEANS on without owning: `join`
    # owns nothing beyond itself, but `include?` answers by calling `==` on the
    # elements and `intersect?` by calling `eql?`/`hash`. A project that
    # redefines one of those makes the value computed in this process disagree
    # with the value the program computes, and the entry's own key says nothing
    # about it — so the entry declares them and they are checked alongside it.
    Entry = _ = Struct.new(:method, :arity, :preflight, :depends_on, keyword_init: true)

    # The element classes a dispatching fold is allowed to see. Not a
    # convenience: `depends_on` has to be a FINITE list, and it can only be
    # finite if the elements are confined to classes the registry already reads
    # reopens of (`LiteralMethodRegistry::CORE_CLASSES`). `true`/`false` are out
    # for the same reason — `TrueClass` is not one of those.
    COMPARABLE_ELEMENTS = [::String, ::Symbol, ::Integer].freeze
    EQUALITY_METHODS = %w[::String#== ::Symbol#== ::Integer#==].freeze
    HASH_METHODS = %w[::String#eql? ::Symbol#eql? ::Integer#eql? ::String#hash ::Symbol#hash ::Integer#hash].freeze

    class << self
      def fold(call:, receiver_type:, argument_types:, override_registry:)
        return nil unless operand?(receiver_type)
        return nil unless argument_types.all? { |type| operand?(type) }

        key = resolved_method_key(call) or return nil
        entry = ENTRIES[key] or return nil
        return nil if override_registry.blocked?(key)
        return nil if entry.depends_on&.any? { |dependency| override_registry.blocked?(dependency) }
        source_location = entry.method.source_location
        return nil if source_location && !source_location.first.start_with?("<internal:")
        return nil unless entry.arity === argument_types.size

        receiver = operand_value(receiver_type)
        arguments = argument_types.map { |type| operand_value(type) }
        return nil unless within_input_budget?(receiver, arguments)
        return nil unless entry.preflight.call(receiver, arguments)

        value = entry.method.bind(receiver).call(*arguments)
        return nil unless literal_value?(value)

        type = AST::Types::Literal.new(value: value)
        return nil if type.to_s.bytesize > result_budget(receiver, arguments)

        type
      rescue ArgumentError, EncodingError, RangeError, ZeroDivisionError => exn
        Steep.logger.debug do
          "[literal_intrinsics] declined #{key || "(unresolved)"}: #{exn.class}: #{exn.message}"
        end
        nil
      rescue StandardError => exn
        # Folding is optional, so an evaluator bug must not take down type
        # checking. Unlike expected runtime failures above, it must be visible.
        Steep.logger.warn do
          "[literal_intrinsics] unexpected failure for #{key || "(unresolved)"}: #{exn.class}: #{exn.message}"
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
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end

      private

      def resolved_method_key(call)
        names = call.method_decls.map { |decl| decl.method_name.to_s }.uniq
        return nil unless names.size == 1

        names.first.start_with?("::") ? names.first : "::#{names.first}"
      end

      # A literal, or a tuple of things that are themselves operands. Nested
      # because a tuple of tuples is what a method's parameter list looks like,
      # and there is nothing to gain by refusing one depth.
      def operand?(type)
        case type
        when AST::Types::Literal then true
        when AST::Types::Tuple then type.types.all? { |element| operand?(element) }
        else false
        end
      end

      def operand_value(type)
        type.is_a?(AST::Types::Tuple) ? type.types.map { |element| operand_value(element) } : type.value
      end

      def within_input_budget?(receiver, arguments)
        [receiver, *arguments].all? do |value|
          next false if collection_size(value) > MAX_COLLECTION_SIZE

          operand_width(value) <= (value.is_a?(::Array) ? MAX_OPERAND_WIDTH : MAX_LITERAL_WIDTH)
        end
      end

      # How wide the result may be. A fold that only reassembles its operands —
      # `join`, `first`, `+` — cannot outgrow them, so bytes already written in
      # the file are always affordable; `'x' * 1000` and `2 ** 4096` COMPUTE
      # theirs out of tiny operands and stay bounded by MAX_LITERAL_WIDTH. The
      # rule falls out of the operands and needs no per-entry taxonomy.
      def result_budget(receiver, arguments)
        [MAX_LITERAL_WIDTH, operand_width(receiver) + arguments.sum { |value| operand_width(value) }].max
      end

      def operand_width(value)
        return AST::Types::Literal.new(value: value).to_s.bytesize unless value.is_a?(::Array)

        value.sum { |element| operand_width(element) + 2 }
      end

      def collection_size(value)
        return 0 unless value.is_a?(::Array)

        value.sum { |element| 1 + collection_size(element) }
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
    ARRAY_JOIN = lambda do |receiver, arguments|
      arguments.size == 1 && arguments.first.is_a?(String) &&
        receiver.all? { |element| element.is_a?(String) }
    end
    # `include?` and `intersect?` compare their operands, and comparison is a
    # CALL. Confining both sides to the classes above is what makes the list of
    # methods that call reaches finite, and therefore watchable.
    COMPARABLE = ->(value) { COMPARABLE_ELEMENTS.any? { |klass| value.is_a?(klass) } }
    ARRAY_INCLUDE = lambda do |receiver, arguments|
      arguments.size == 1 && COMPARABLE[arguments.first] && receiver.all?(&COMPARABLE)
    end
    ARRAY_INTERSECT = lambda do |receiver, arguments|
      other = arguments.first
      arguments.size == 1 && other.is_a?(::Array) &&
        receiver.all?(&COMPARABLE) && other.all?(&COMPARABLE)
    end
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
      "::String#to_sym" => Entry.new(method: String.instance_method(:to_sym), arity: 0, preflight: ALWAYS),
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
      # `::Array#first` is deliberately NOT here, though it folds as safely as
      # these do. `[1].first` is how a good deal of code — the checker's own
      # tests included — asks for an `Integer?`, and sharpening it to `1` turns
      # the `return unless a` that follows into an unreachable branch. The fold
      # is right and the change is real, so it belongs in the stage that has a
      # use for it (`parameters.map(&:first)`, S2/S3 of #171) and can carry the
      # test edits it forces, not in the one that needs `join`.
      "::Array#join" => Entry.new(method: Array.instance_method(:join), arity: 1, preflight: ARRAY_JOIN),
      "::Array#include?" => Entry.new(
        method: Array.instance_method(:include?), arity: 1, preflight: ARRAY_INCLUDE,
        depends_on: EQUALITY_METHODS
      ),
      "::Array#intersect?" => Entry.new(
        method: Array.instance_method(:intersect?), arity: 1, preflight: ARRAY_INTERSECT,
        depends_on: EQUALITY_METHODS + HASH_METHODS
      )
    }.freeze
  end
end

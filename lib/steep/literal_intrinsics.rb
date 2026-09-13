module Steep
  # Exact return types for a deliberately small set of Ruby core operations on
  # literal values. This is not general constant evaluation: dispatch has
  # already succeeded against RBS, every operand must be a literal, the method
  # must resolve to one closed-table core identity, and any project override
  # disables the entry.
  module LiteralIntrinsics
    MAX_LITERAL_WIDTH = 64
    MAX_INTEGER_BITS = 256

    Entry = _ = Struct.new(:method, :arity, :preflight, keyword_init: true)

    class << self
      def fold(call:, receiver_type:, argument_types:, override_registry:)
        return nil unless receiver_type.is_a?(AST::Types::Literal)
        return nil unless argument_types.all? { |type| type.is_a?(AST::Types::Literal) }

        key = resolved_method_key(call) or return nil
        entry = ENTRIES[key] or return nil
        return nil if override_registry.blocked?(key)
        source_location = entry.method.source_location
        return nil if source_location && !source_location.first.start_with?("<internal:")
        return nil unless entry.arity == argument_types.size

        receiver = receiver_type.value
        arguments = argument_types.map(&:value)
        return nil unless within_input_budget?(receiver, arguments)
        return nil unless entry.preflight.call(receiver, arguments)

        value = entry.method.bind(receiver).call(*arguments)
        return nil unless literal_value?(value)

        type = AST::Types::Literal.new(value: value)
        return nil if type.to_s.bytesize > MAX_LITERAL_WIDTH

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

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        ENTRIES.each_key.select { |key| key.start_with?(prefix) }
      end

      private

      def resolved_method_key(call)
        names = call.method_decls.map { |decl| decl.method_name.to_s }.uniq
        return nil unless names.size == 1

        names.first.start_with?("::") ? names.first : "::#{names.first}"
      end

      def within_input_budget?(receiver, arguments)
        [receiver, *arguments].all? do |value|
          AST::Types::Literal.new(value: value).to_s.bytesize <= MAX_LITERAL_WIDTH
        end
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
      "::Symbol#to_s" => Entry.new(method: Symbol.instance_method(:to_s), arity: 0, preflight: ALWAYS)
    }.freeze
  end
end

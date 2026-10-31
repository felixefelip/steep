module Steep
  # Values the source spells out as syntax, where the checker types the node as
  # its class: a regexp, a range of integers, a string or symbol with
  # interpolations.
  # Each interpolation counts only when what it splices in is a literal.
  module LiteralSyntax
    # The flags a literal can carry without changing what its source means.
    # `o` only says when an interpolation is evaluated, and every one read here
    # is a literal, the same each time; the encoding flags (`n`, `e`, `s`, `u`)
    # change how the bytes are read, and decline.
    REGEXP_OPTIONS = { i: Regexp::IGNORECASE, x: Regexp::EXTENDED, m: Regexp::MULTILINE, o: 0 }.freeze

    # `/…/`, as the patterns it may evaluate to. Ruby splices an interpolation
    # in unescaped, as source.
    def self.regexp(node, typing)
      *parts, flags = node.children
      options = flags.children.sum { |flag| REGEXP_OPTIONS.fetch(flag) { return nil } }
      sources = texts(parts, typing) or return nil

      AST::Types::Union.build(types: sources.map { |source| AST::Types::RegexpLiteral.new(value: Regexp.new(source, options)) })
    rescue RegexpError, Typing::UnknownNodeError
      nil
    end

    def self.string(node, typing)
      strings = texts(node.children, typing) or return nil

      AST::Types::Union.build(types: strings.map { |text| AST::Types::Literal.new(value: text) })
    end

    def self.symbol(node, typing)
      names = texts(node.children, typing) or return nil

      AST::Types::Union.build(types: names.map { |name| AST::Types::Literal.new(value: name.to_sym) })
    end

    # `1..-1` with each end an integer written out, or left open.
    def self.range(node)
      first, last = node.children.map do |bound|
        next nil unless bound
        return nil unless bound.type == :int

        bound.children[0]
      end

      AST::Types::RangeLiteral.new(value: ::Range.new(first, last, node.type == :erange))
    end

    def self.texts(parts, typing)
      parts.inject([""]) do |prefixes, part|
        pieces = pieces(part, typing) or return nil

        prefixes.product(pieces).map(&:join)
      end.uniq
    end

    # A literal written inside `#{}` is read off its node, since the checker
    # types it as its class.
    def self.pieces(part, typing)
      return [part.children[0]] if part.type == :str

      written = part.children[0] if part.type == :begin && part.children.one?
      return [written.children[0].to_s] if written && %i[str sym int].include?(written.type)

      type = typing.type_of(node: part)
      members = type.is_a?(AST::Types::Union) ? type.types : [type]
      members.map { |member| member.is_a?(AST::Types::Literal) ? member.value.to_s : (return nil) }
    end
  end
end

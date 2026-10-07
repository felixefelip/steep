module Steep
  # Which calls leave a String's value as it was (felixefelip/steep#207).
  #
  # A literal type names a value, and a String's value can change in place:
  #
  #     result = word.dup        # "posts"
  #     result.sub!(/s\z/, "")
  #     result                   # "post" — but still typed "posts"
  #
  # So a call on a receiver typed by a String literal is taken to change it,
  # and the receiver widens to `::String` — unless the method is one of the
  # closed list below, each of which reads the string or returns a new one.
  # A list of what is SAFE, not of what mutates: a method this list has never
  # heard of — a newer Ruby's, a project's own — widens, which costs precision
  # and never correctness.
  #
  # Keyed like the intrinsic tables, by the method the call RESOLVED to, and
  # watched by the same registry: a project that redefines one of these has
  # written what the program runs instead, and that entry stops vouching.
  module StringMutation
    ENTRIES = (
      %w[
        -@ [] * % + +@ <=> == === =~ ascii_only? b byteindex byterindex bytes
        bytesize byteslice capitalize casecmp casecmp? center chars chomp chop chr
        codepoints count crypt dedup delete delete_prefix delete_suffix downcase
        dump each_byte each_char each_codepoint each_grapheme_cluster each_line
        empty? encode encoding end_with? eql? freeze getbyte grapheme_clusters gsub
        hash hex include? index inspect intern length lines ljust lstrip match
        match? next oct ord partition reverse rindex rjust rpartition rstrip scan
        scrub size slice split squeeze start_with? strip sub succ sum swapcase to_c
        to_f to_i to_r to_s to_str to_sym tr tr_s undump unicode_normalize
        unicode_normalized? unpack unpack1 upcase upto valid_encoding?
      ].map { |name| "::String##{name}" } +
      %w[< <= > >= between? clamp].map { |name| "::Comparable##{name}" } +
      %w[!~ class clone dup frozen? instance_of? is_a? itself kind_of? nil? object_id respond_to?]
        .map { |name| "::Kernel##{name}" } +
      %w[! != equal? __id__].map { |name| "::BasicObject##{name}" }
    ).to_h { |key| [key, true] }.freeze

    class << self
      # The type `type` is once the value it names may have changed: each
      # String literal in it as `::String`. The same object where there is none.
      def widen(type)
        case type
        when AST::Types::Literal
          type.value.is_a?(::String) ? AST::Builtin::String.instance_type : type
        when AST::Types::Union, AST::Types::Intersection
          types = type.types.map { |member| widen(member) }
          return type if types.zip(type.types).all? { |widened, member| widened.equal?(member) }

          type.is_a?(AST::Types::Union) ? AST::Types::Union.build(types: types) : AST::Types::Intersection.build(types: types)
        else
          type
        end
      end

      # Whether a call through `keys` — every method it may resolve to — leaves
      # the receiver's value as it was. A call with a block never does: the
      # block can reach the receiver through a name it closes over.
      def preserves?(keys, block:, override_registry:)
        return false if block || keys.empty?

        keys.all? { |key| ENTRIES.key?(key) && !override_registry.blocked?(key) }
      end

      def watched_keys
        @watched_keys ||= Set.new(ENTRIES.keys)
      end

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end
    end
  end
end

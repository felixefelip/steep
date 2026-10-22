module Steep
  # Core methods that neither change nor keep a value handed to them as an
  # argument: what a block handed a collection's elements may pass them to and
  # leave the collection as it was (`TypeInference::ClassMemoAnalyzer`).
  #
  # Keyed like the intrinsic tables, by the method a call resolves to, and
  # watched by the same registry: a project that redefines one has written what
  # the program runs instead. A block names its calls by spelling only, so each
  # name stands for every key below it.
  module ElementReads
    ENTRIES = (
      %w[
        sub sub! gsub gsub! match match? =~ === == != eql? start_with? end_with? include?
        index rindex tr delete count scan split partition rpartition casecmp casecmp? <=> + %
      ].map { |name| "::String##{name}" } +
      %w[match match? =~ === ==].map { |name| "::Regexp##{name}" } +
      %w[== != equal? eql?].map { |name| "::BasicObject##{name}" }
    ).to_h { |key| [key, true] }.freeze

    NAMES = ENTRIES.keys.map { |key| key.split("#", 2).last.to_sym }.uniq.freeze

    # The ones that neither change nor keep their RECEIVER either, so an element
    # may be the value a call is made on: `regex.match?(word)`. `match` and
    # `=~` are left out, because the `MatchData` they leave in `$~` holds on to
    # the pattern.
    RECEIVER_ENTRIES = (
      %w[match? == != eql?].map { |name| "::Regexp##{name}" } +
      %w[match? == != eql?].map { |name| "::String##{name}" } +
      %w[== != equal? eql?].map { |name| "::BasicObject##{name}" }
    ).to_h { |key| [key, true] }.freeze

    RECEIVER_NAMES = RECEIVER_ENTRIES.keys.map { |key| key.split("#", 2).last.to_sym }.uniq.freeze

    class << self
      def keys_for(method_name)
        watched_keys.select { |key| key.end_with?("##{method_name}") }
      end

      def watched_keys
        @watched_keys ||= Set.new(ENTRIES.keys + RECEIVER_ENTRIES.keys)
      end

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end
    end
  end
end

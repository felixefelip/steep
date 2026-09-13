module Steep
  # Per-argument-tuple return types (felixefelip/rbs_infer#345, stage S4).
  #
  # A declaration holds for every caller, so `(?flag_name: bool) -> String`
  # cannot say that the callers passing `true` get `"name_delete"`. That fact
  # lives in a sidecar, keyed by the method and by the argument types the call
  # site supplies:
  #
  #     ---
  #     version: 1
  #     methods:
  #       Example69::Foo#call:
  #         "(flag_name: true)": '"name_delete"'
  #         "(flag_name: false)": '"delete"'
  #
  # `Specializations::Runner` writes it, `TypeConstruction` reads it back at the
  # send and replaces the call's return type.
  module Specializations
    DEFAULT_SIDECAR_PATH = "sig/generated/.steep_specializations.yml".freeze
    SCHEMA_VERSION = 1

    class << self
      def load(base_dir, path: DEFAULT_SIDECAR_PATH)
        absolute = base_dir + path
        return Store.empty unless absolute.file?

        raw = YAML.safe_load(absolute.read, aliases: true)
        Store.from_hash(raw, source: absolute.to_s)
      rescue Psych::Exception, LoadError => exn
        Steep.logger.warn { "[specializations] failed to parse #{absolute}: #{exn.message}" }
        Store.empty
      end

      # `type` with every literal replaced by the class it instantiates. The
      # widening operator of the fixpoint: a value that keeps changing is a value
      # the program does not fix, and its class is what it does fix.
      def widen_literals(type)
        return type.back_type if type.is_a?(AST::Types::Literal)

        type.map_type { |child| widen_literals(child) }
      end

      # `"Foo#bar"` / `"Foo.bar"` for a resolved call, matching how a `def` in the
      # source keys itself. nil when the call resolves to more than one
      # declaration — the argument tuple then names no single body to specialize.
      def method_key(method_decls)
        return nil unless method_decls.size == 1

        method_decls.first.method_name.to_s.delete_prefix("::")
      end
    end

    # The argument types of one call, in the spelling both sides key on.
    class Arguments
      attr_reader :positionals, :keywords

      # The argument types of `node`, or nil when the call has a shape no tuple
      # describes: a splat, a block pass, a non-symbol keyword. A call with no
      # literal among its arguments answers nil too — specializing it would
      # record the declaration back.
      def self.from_send(node, typing)
        _receiver, _name, *args = node.children

        keywords = {} #: Hash[Symbol, AST::Types::t]
        if args.last&.type == :kwargs
          args.pop.children.each do |pair|
            return nil unless pair.type == :pair

            key, value = pair.children
            return nil unless key.type == :sym

            type = typing.has_type?(value) ? typing.type_of(node: value) : nil
            return nil unless type

            keywords[key.children[0]] = type
          end
        end

        positionals = [] #: Array[AST::Types::t]
        args.each do |arg|
          return nil if arg.type == :splat || arg.type == :block_pass
          return nil unless typing.has_type?(arg)

          positionals << typing.type_of(node: arg)
        end

        arguments = new(positionals: positionals, keywords: keywords)
        arguments.literal? ? arguments : nil
      end

      def initialize(positionals:, keywords:)
        @positionals = positionals
        @keywords = keywords
      end

      def key
        parts = positionals.map(&:to_s)
        parts.concat(keywords.keys.sort.map { |name| "#{name}: #{keywords[name]}" })
        "(#{parts.join(", ")})"
      end

      def literal?
        positionals.any? { |type| literal_type?(type) } ||
          keywords.each_value.any? { |type| literal_type?(type) }
      end

      def empty?
        positionals.empty? && keywords.empty?
      end

      # `method_type` with each parameter this call fixed replaced by the type it
      # was passed. Parameters the call leaves to their default keep the declared
      # type; a positional past a rest parameter is left alone, because the index
      # no longer names one parameter.
      def substitute(method_type)
        function = method_type.type
        return method_type unless function.is_a?(Interface::Function)

        params = function.params.update(
          positional_params: substitute_positionals(function.params.positional_params),
          keyword_params: substitute_keywords(function.params.keyword_params)
        )

        method_type.with(type: function.with(params: params))
      end

      def ==(other)
        other.is_a?(Arguments) && other.positionals == positionals && other.keywords == keywords
      end

      alias eql? ==

      def hash
        positionals.hash ^ keywords.hash
      end

      private

      def literal_type?(type)
        type.is_a?(AST::Types::Literal)
      end

      # A positional index names one parameter only up to the first rest
      # parameter; past it, `positionals` is exhausted so the tail is left alone.
      def substitute_positionals(params)
        return params unless params

        index = 0
        params.map do |param|
          case param
          when Interface::Function::Params::PositionalParams::Required,
               Interface::Function::Params::PositionalParams::Optional
            type = positionals[index]
            index += 1
            type ? param.map_type { type } : param
          else
            index = positionals.size
            param
          end
        end
      end

      def substitute_keywords(params)
        return params if keywords.empty?

        params.update(
          requireds: substitute_keyword_hash(params.requireds),
          optionals: substitute_keyword_hash(params.optionals)
        )
      end

      def substitute_keyword_hash(hash)
        hash.each_key.with_object({}) do |name, result|
          result[name] = keywords.fetch(name, hash[name])
        end
      end
    end

    class Store
      attr_reader :methods, :source, :active

      def self.empty
        new(methods: {}, source: nil)
      end

      def self.from_hash(raw, source:)
        version = raw && raw["version"]
        if version && version != SCHEMA_VERSION
          Steep.logger.warn { "[specializations] unsupported sidecar version #{version} (expected #{SCHEMA_VERSION}); ignoring #{source}" }
          return empty
        end

        methods = {} #: Hash[String, Hash[String, String]]
        ((raw && raw["methods"]) || {}).each do |method_key, entries|
          next unless entries.is_a?(Hash)

          methods[method_key] = entries.select { |key, type| key.is_a?(String) && type.is_a?(String) }
        end

        new(methods: methods, source: source)
      end

      def initialize(methods:, source:, active: {})
        @methods = methods
        @source = source
        @active = active
      end

      def empty?
        @methods.empty? && @active.empty?
      end

      # The recorded return type for `method_key` called with `argument_key`, as a
      # Steep type, or nil when nothing was recorded or the entry no longer parses.
      def return_type(method_key, argument_key, factory:)
        raw = @methods.dig(method_key, argument_key) or return nil

        factory.type(RBS::Parser.parse_type(raw).map_type_name { |name, _, _| name.absolute! })
      rescue RBS::ParsingError, RBS::BaseError => exn
        Steep.logger.warn { "[specializations] unparsable type #{raw.inspect} for #{method_key}: #{exn.message}" }
        nil
      end

      # The argument types a specialization pass is currently checking
      # `method_key`'s body under — nil during an ordinary type check, where every
      # body is checked once under its declaration.
      def active_arguments(method_key)
        @active[method_key]
      end

      def with_active(active)
        Store.new(methods: @methods, source: @source, active: active)
      end
    end
  end
end

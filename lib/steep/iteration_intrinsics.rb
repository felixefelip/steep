module Steep
  # Block calls on a collection whose elements the checker knows, answered by
  # checking the block once per element. Not an interpreter: each pass is the
  # ordinary check of the body with its parameters bound to one element, which
  # is what the checker already does for `each` (`record_iterations`) and what
  # `Specializations::Runner` does per call site.
  #
  #     parameters.map(&:first)                          # [:req, :opt]
  #     parameters.filter_map { |type, arg| arg if type == :req }   # [:a]
  #
  # The table is keyed like the other two, by the method the call RESOLVED to,
  # and the registry reads it the same way: a project that reopens one of these
  # methods, or one an entry leans on, turns the entry off.
  module IterationIntrinsics
    # `collect` says what a pass contributes: `:each` nothing (its passes are
    # read for their pushes, not their values), `:map` the value the block
    # hands back, `:filter_map` that value only where it is truthy.
    #
    # `depends_on` as in `LiteralIntrinsics`: `Enumerable#filter_map` walks the
    # receiver by calling its `each`, so an `Array#each` the project replaced is
    # what the program runs instead. And it is reached through `Array`: a
    # `filter_map` the project writes on `Array` — reopened, or from a module
    # it includes — is found first and still resolves, by its RBS, here.
    Entry = _ = Struct.new(:collect, :depends_on, keyword_init: true)

    ENTRIES = {
      "::Array#each" => Entry.new(collect: :each),
      # Two names for one implementation, and two entries: a call resolves to
      # the name it was made by, and reopening one of them leaves the other as
      # it was.
      "::Array#map" => Entry.new(collect: :map),
      "::Array#collect" => Entry.new(collect: :map),
      "::Enumerable#filter_map" => Entry.new(collect: :filter_map, depends_on: ["::Array#each", "::Array#filter_map"])
    }.freeze

    # What `map(&:first)` leans on to call `first` at all.
    SYMBOL_TO_PROC = "::Symbol#to_proc"

    class << self
      def entry(key, override_registry:)
        entry = ENTRIES[key] or return nil
        return nil if override_registry.blocked?(key)
        return nil if entry.depends_on&.any? { |dependency| override_registry.blocked?(dependency) }

        entry
      end

      def watched_keys
        @watched_keys ||= Set.new(
          ENTRIES.keys + ENTRIES.each_value.flat_map { |entry| entry.depends_on || [] } + [SYMBOL_TO_PROC]
        )
      end

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end

      # The collection the passes hand back, or nil where one of them does not
      # say exactly what it contributes. A value is exact when it is a value the
      # fold can go on to read; anything wider is the declaration's to type.
      def collect(entry, results)
        types =
          case entry.collect
          when :map
            return nil unless results.all? { |type| exact?(type) }

            results
          when :filter_map
            results.each_with_object([]) do |type, kept|
              case truthiness(type)
              when :truthy
                return nil unless exact?(type)

                kept << type
              when :falsy
                next
              else
                return nil
              end
            end
          end

        types && AST::Types::Tuple.new(types: types)
      end

      def truthiness(type)
        case type
        when AST::Types::Nil then :falsy
        when AST::Types::Literal then type.value == false ? :falsy : :truthy
        when AST::Types::Tuple, AST::Types::FiniteSet, AST::Types::RegexpLiteral, AST::Types::ObjectState then :truthy
        end
      end

      # The block's parameters bound to one element, the way `yield element`
      # binds them: one parameter takes the element, several or a pattern take it
      # apart. Anything else — a rest, an optional — declines.
      #
      # One parameter is `procarg0` only when written `|k|`. `|k,|` parses as a
      # plain `arg`, and Ruby takes the element apart for it as for several:
      # `[["ab", "cde"]].map { |k,| k }` is `["ab"]`.
      def element_bindings(block_params, element)
        return if block_params.rest_param || block_params.block_param || !block_params.optional_params.empty?

        params = block_params.params
        return {} if params.empty?

        if params.size == 1 && params[0].node.type == :procarg0
          return { params[0].var => element } if params[0].is_a?(TypeInference::BlockParams::Param)

          params = params[0].params
        end
        destructured_bindings(params, element)
      end

      def destructured_bindings(params, element)
        return unless element.is_a?(AST::Types::Tuple)

        params.each_with_index.each_with_object({}) do |(param, index), bindings|
          value = element.types[index] || AST::Builtin.nil_type
          nested =
            case param
            when TypeInference::BlockParams::MultipleParam then destructured_bindings(param.params, value)
            when TypeInference::BlockParams::Param then ({ param.var => value } if param.node.type == :arg)
            end
          bindings.merge!(nested || (return nil))
        end
      end

      private

      def exact?(type)
        case type
        when AST::Types::Literal, AST::Types::Nil, AST::Types::RegexpLiteral then true
        when AST::Types::Tuple, AST::Types::FiniteSet then type.types.all? { |element| exact?(element) }
        else false
        end
      end
    end
  end
end

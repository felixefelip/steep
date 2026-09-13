module Steep
  module Specializations
    # The source a method writes with `class_eval`/`module_eval` on a STRING,
    # read at one call site of that method.
    #
    #     def has_rich_text(name)
    #       class_eval "def #{name}; rich_text_#{name}; end"
    #     end
    #
    #     has_rich_text :content
    #
    # A checker cannot see inside that string, and neither can any other static
    # reader: the text does not exist until an argument supplies it. But it is
    # not dynamic in the `eval`/`method_missing` sense — the call site says what
    # `name` is, and a specialized body types `name` as `:content`, so the
    # interpolation folds to a literal and the string IS its own type.
    #
    # That is all this reads. Nothing here parses Ruby, decides a branch or
    # binds a parameter; the specialization pass has already done each of those
    # as type inference, and this takes the answers off the typing.
    module Evals
      EVAL_METHODS = %i[class_eval module_eval].freeze

      # Written, never read back: nothing in Steep needs the text, since a
      # string it can fold is a string it has already typed. It is written for
      # the generator on the other side, which turns it into the Ruby the class
      # actually has (felixefelip/rbs_infer#343).
      DEFAULT_OUTPUT_PATH = Pathname("sig/generated/.steep_string_evals.yml").freeze
      SCHEMA_VERSION = 1

      # A dead branch still gets a type — Steep synthesizes it to report errors
      # in it — so "folded to a literal" does not mean "runs". These are the
      # diagnostics that say it does not.
      UNREACHABLE = [
        Diagnostic::Ruby::UnreachableBranch,
        Diagnostic::Ruby::UnreachableValueBranch
      ].freeze

      class << self
        # Whether the method writes code at all, which is the gate that keeps a
        # project without the idiom from paying for a single extra check.
        def writes_code?(def_node)
          each_eval_send(def_node) { return true }
          false
        end

        # The strings this body evals, in source order, with nil for one whose
        # value this call site does not fix. A nil is reported rather than
        # dropped: a consumer rendering the list needs to know its macro was
        # read in part, since a class given a reader whose writer was skipped
        # is worse than one given neither.
        def sources(typing, def_node)
          dead = unreachable_ranges(typing)
          result = [] #: Array[String?]

          each_eval_send(def_node) do |node|
            next if dead.any? { |range| covers?(range, node.loc.expression) }

            result << literal_string(typing, node)
          end

          result
        end

        private

        def each_eval_send(node, &block)
          return unless node.is_a?(Parser::AST::Node)

          if eval_send?(node)
            yield node
            return
          end

          node.children.each { |child| each_eval_send(child, &block) }
        end

        # A receiverless `class_eval` with a string argument. One with a block is
        # `ClassEvalExpander`'s shape and is plain Ruby a reader already sees;
        # one with a receiver evals somewhere this method's parameters do not
        # name.
        def eval_send?(node)
          return false unless node.type == :send && node.children[0].nil?
          return false unless EVAL_METHODS.include?(node.children[1])

          argument = node.children[2]
          argument&.type == :str || argument&.type == :dstr
        end

        def literal_string(typing, node)
          argument = node.children[2]
          return nil unless typing.has_type?(argument)

          type = typing.type_of(node: argument)
          return nil unless type.is_a?(AST::Types::Literal) && type.value.is_a?(String)

          type.value
        end

        def unreachable_ranges(typing)
          typing.errors.filter_map do |error|
            next unless UNREACHABLE.any? { |klass| error.is_a?(klass) }

            error.node&.loc&.expression
          end
        end

        def covers?(range, other)
          other && range.begin_pos <= other.begin_pos && other.end_pos <= range.end_pos
        end
      end
    end
  end
end

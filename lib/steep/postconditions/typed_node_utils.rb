module Steep
  module Postconditions
    # Typed-AST helpers shared by the postcondition inferrers
    # (`Inferrer`, `MethodEntryInferrer` and `ReturnEstablishmentInferrer`).
    # The includer must expose a `@typing` (`Typing`) instance variable, and a
    # `@subtyping` (`Subtyping::Check`) one if it calls `strict_subtype?`.
    module TypedNodeUtils
      # The full resolved name of a constant node (`Registry` written inside
      # `Outer` => `Outer::Registry`), read off its singleton type so every
      # sidecar key names the constant by IDENTITY rather than by how it happened
      # to be spelled. This is the write-side counterpart of
      # `TypeConstruction#resolved_const_name_string`, which resolves the same way
      # on the read side; the two must agree or a fact is written under one key
      # and looked up under another, and the proof silently evaporates.
      #
      # Falls back to the lexical path when no singleton type is available — for a
      # top-level constant the two coincide, so nothing is lost there. Either way
      # a leading `::` is dropped, so an absolute spelling (`::Current.user`) keys
      # the same slot as the relative one, exactly as the read side does.
      def resolved_const_name(node)
        type = type_of(node)
        return type.name.to_s.sub(/\A::/, "") if type.is_a?(AST::Types::Name::Singleton)

        lexical_const_name(node)&.sub(/\A::/, "")
      end

      # `(:const nil :Current)` / `(:const (:const nil :A) :B)` => "Current" / "A::B".
      def lexical_const_name(node)
        return nil unless node.is_a?(Parser::AST::Node) && node.type == :const

        parent, name = node.children
        parent ? "#{lexical_const_name(parent)}::#{name}" : name.to_s
      end

      def type_of(node)
        @typing.type_of(node: node)
      rescue Typing::UnknownNodeError
        nil
      end

      # Returns the intrinsic (hint-free) type of a node. For literal
      # AST nodes — `:str`, `:int`, `:sym`, etc. — Steep's `:ivasgn`
      # handler passes the LHS's declared type to `synthesize` as a
      # `hint:`, which widens the literal's emitted type to match the
      # declared one (e.g. `@name = "x"` with `@name: String?` ends up
      # with the str node typed as `(String | nil)`, not `String`).
      # The widening is useful for collections (`Array[Integer] !<:
      # Array[Numeric]` would otherwise fail to assign), but it makes
      # narrowing detection silently no-op for the common
      # setter-with-literal pattern.
      #
      # For literal nodes we compute the type directly from the node
      # shape, matching what `synthesize` would return if hint were
      # nil. For non-literal nodes (sends, lvars, dstrs, arrays, …)
      # we fall back to the typed-out `type_of` — those rarely suffer
      # the widening issue since the hint mostly affects literal
      # value-class lookups.
      #
      # Tracked in felixefelip/steep#34; the upstream-friendly
      # follow-up would expose `synthesize(node, hint: nil)` as a
      # general-purpose helper.
      def intrinsic_type_of(node)
        case node.type
        when :nil
          AST::Builtin.nil_type
        when :str, :dstr
          AST::Builtin::String.instance_type
        when :int
          AST::Builtin::Integer.instance_type
        when :float
          AST::Builtin::Float.instance_type
        when :sym, :dsym
          AST::Builtin::Symbol.instance_type
        when :true
          AST::Types::Literal.new(value: true)
        when :false
          AST::Types::Literal.new(value: false)
        when :regexp
          AST::Builtin::Regexp.instance_type
        else
          type_of(node)
        end
      end

      # Unwraps `:begin`/`:kwbegin` wrappers down to the syntactic last
      # expression of a body (the method's return value under linear flow).
      def last_expression(node)
        case node&.type
        when :begin, :kwbegin
          last = node.children.compact.last
          last ? last_expression(last) : nil
        else
          node
        end
      end

      # Strict subtype check: `sub_type <: super_type` and the two are
      # not structurally equal. Equality short-circuits the subtype call
      # for the common case of `@x = same_type_method` (no refinement
      # opportunity).
      def strict_subtype?(sub_type, super_type)
        return false if sub_type == super_type
        @subtyping.check(
          Subtyping::Relation.new(sub_type: sub_type, super_type: super_type),
          self_type: AST::Builtin::Object.instance_type,
          instance_type: AST::Builtin::Object.instance_type,
          class_type: AST::Builtin::Object.module_type,
          constraints: Subtyping::Constraints.empty
        ).success?
      end
    end
  end
end

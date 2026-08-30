# frozen_string_literal: true

require "yaml"

module Steep
  class Source
    # Injects convention annotations into module/concern sources at parse time,
    # driven by a sidecar (`sig/generated/.steep_module_self_types.yml`)
    # produced by a framework-aware generator (e.g. rbs_infer). Two kinds:
    #
    #   * `# @type self:` / `# @type instance:` placed inside a module body
    #     (the `anchor` / `annotations` entry keys);
    #   * `# @type self:` on ONE method's signature line (the `defs` entry key),
    #     for when the answer differs per method and the module-wide line above
    #     cannot carry it — see `inject_defs`; and
    #   * `# @implements <Module>` on a DSL block's opener line plus, per spec,
    #     `# @type self: <Type>` on each method-def line in that block (the
    #     `blocks` entry key) — e.g. an `ActiveSupport::Concern`'s
    #     `class_methods do … end`, so Steep checks the block as an
    #     implementation of <Module> (its `def`s attach there) whose method
    #     bodies run with <Type> as self (the including class's singleton, so
    #     the includer's scopes/class methods resolve). Both ride on existing
    #     lines, so no line is added and reported line numbers stay aligned
    #     with the real source. An optional `in:` picks the calls written inside
    #     one class/module, for when the file writes that name more than once
    #     with a different target for each.
    #
    # Steep is framework-agnostic here: it knows nothing about Rails, concerns,
    # or path conventions. It only looks up an entry by path and places the
    # given comment lines at the right AST scope. Deciding *what* to inject
    # (the module's real name, the including class, whether it's a concern, the
    # DSL call name and its target module) is the generator's job — it has the
    # AST and the framework conventions.
    #
    # Sidecar format (keyed by project-relative source path):
    #
    #   "app/models/search/record/sqlite.rb":
    #     modules:
    #       - anchor: "SQLite"
    #         annotations:
    #           - "# @type self: singleton(Search::Record) & singleton(Search::Record::SQLite)"
    #           - "# @type instance: Search::Record & Search::Record::SQLite"
    #         defs:
    #           write: "singleton(Search::Record::Writer)"
    #   "app/models/post/taggable.rb":
    #     blocks:
    #       - call: "class_methods"
    #         implements: "::Post::Taggable::ClassMethods"
    #         self: "singleton(::Post) & singleton(::Post::Taggable)"
    #   "app/models/example29.rb":
    #     blocks:
    #       - call: "bazingado"
    #         in: "::Example29::Baz"
    #         implements: "::Example29::Bar"
    #       - call: "bazingado"
    #         in: "::Example29::BazOther"
    #         implements: "::Example29::BarOther"
    #
    # `anchor` is the leaf constant name; it locates the target scope so a
    # comment for a nested module lands *inside* that module's body (a trailing
    # end-of-file comment would bind to the enclosing scope instead).
    #
    # `modules` is a LIST because one file can declare several, each with its own
    # self type: a framework transcription reopens `Token`, `Token::ControllerMethods`
    # and their wrapper in one file, and only one of them is a mixin. A single
    # `anchor`/`annotations` pair at the top level is still read, so a sidecar
    # written by an older generator keeps working.
    #
    # Block injection relies on the upstream `@implements` annotation — legacy
    # (absent from the current `manual/annotations.md`, but still parsed and
    # handled: `TypeConstruction#for_block` reads it to rebind the block body's
    # module context and self type). No checker change is needed; this only
    # places the comment at the right offset.
    module ModuleSelfTypes
      DEFAULT_SIDECAR_PATH = "sig/generated/.steep_module_self_types.yml"

      class << self
        # The sidecar entry for `path`, or nil. Keys are project-relative; an
        # absolute path matches by its tail.
        def entry_for(path)
          table = load_table
          return nil if table.empty?

          key = path.to_s
          table[key] || table[relative(key)] || table.find { |k, _| key.end_with?("/#{k}") }&.last
        end

        # The `{anchor:, annotations:}` pairs of an entry, one per module the
        # file declares. A top-level `anchor`/`annotations` pair is read as a
        # single-element list, so a sidecar from a generator that predates
        # `modules` still applies.
        def self_types_of(entry)
          modules = Array(entry["modules"])
          return modules if modules.any?

          entry["anchor"] ? [entry] : []
        end

        # The declared PATHS through a method: `[{ "when" => { parameter name
        # => type }, "self" => type }, ...]`, or nil.
        #
        # Unlike everything else here this one is not injected as a comment —
        # there is no annotation that says "when this parameter is that, `self`
        # is this", which is exactly why it needs a channel of its own. It is
        # read at check time, by the send path, when a call's receiver is a
        # union: each branch is checked with the `self` its path declares
        # instead of all of them being merged into one method type
        # (felixefelip/rbs_infer#231, felixefelip/steep#143).
        #
        # Two parameters of one method travel together across its call sites,
        # and nothing in RBS states that: the signature admits every pairing,
        # while the program only ever makes some. The generator reads which,
        # and this is where it says so.
        def paths_of(entry, anchor, method_name)
          modules = Array(entry["modules"])
          modules = entry["anchor"] ? [entry] : [] if modules.empty?

          mod = modules.find { |m| m["anchor"].to_s == anchor.to_s } or return nil
          paths = mod["paths"] or return nil
          return nil unless paths.is_a?(Hash)

          entries = paths[method_name.to_s]
          return nil unless entries.is_a?(Array) && !entries.empty?
          return nil unless entries.all? { |e| e.is_a?(Hash) && e["when"].is_a?(Hash) && e["self"].is_a?(String) }

          entries
        end

        # Places `annotations` INSIDE the body of the scope named `anchor`.
        # Lines already present are skipped, so it's idempotent. Purely
        # mechanical — no framework knowledge.
        #
        # An annotation only binds to the scope it is written in, so the body
        # is the only placement that always holds. End-of-file used to be used
        # for a top-level module, to keep every original line number: a
        # trailing comment binds to the file's sole node, which for a one-module
        # file IS that module. It stops being that node the moment the file
        # writes anything else at the top level — a second module, a reopen, the
        # pseudo-code a generator appends — and then the comments bind to the
        # file's `begin` instead and the module silently keeps Steep's default
        # `(::Object & ::TheModule)` self, the very answer the annotation exists
        # to replace (felixefelip/steep#155). Nothing failed and nothing said so;
        # a concern's `self.class.some_class_method` just went `untyped`.
        #
        # In-body placement costs the module's own `end` line, and any line
        # after it, a two-line shift — the same cost the nested case has always
        # paid. A concern file is one module ending at end-of-file, so there is
        # normally no line after it to move.
        def inject(source_code, annotations:, anchor:)
          missing = annotations.reject { |line| source_code.include?(line) }
          return source_code if missing.empty?

          node = find_target_scope(source_code, anchor)
          if node
            insert_in_body(source_code, node, missing)
          else
            append_at_end(source_code, missing)
          end
        rescue StandardError
          append_at_end(source_code, missing)
        end

        # Annotates each block call named `call`, for every `blocks` spec
        # (`{ "call" => ..., "implements" => ..., "self" => ..., "in" => ...,
        # "method" => ... }`): `# @implements <implements>` on the opener line, and — when
        # `self` is given — `# @type self: <self>` on each method-def line in
        # the block (see `block_annotation_insertions`). Lets Steep check a DSL
        # block — e.g. `class_methods do … end` — as an implementation of the
        # target module whose methods run with the includer's class self.
        # Every comment rides on an existing line, so it adds NO line: Steep
        # reports against the injected source, and every line number stays
        # aligned with the real file (the same line-preservation guarantee
        # `inject` keeps). Idempotent and purely mechanical; falls back to the
        # original source on any parse error.
        def inject_blocks(source_code, blocks:)
          return source_code if blocks.empty?

          result = Prism.parse(source_code)
          return source_code unless result.success?

          insertions = blocks.flat_map do |spec|
            call_name = spec["call"].to_s
            # A LIST is allowed, and joined into ONE comment rather than written
            # as several. A block replayed onto two classes defines its methods
            # on both, and the annotation rides the block's opener line — so a
            # second `# @implements` would be spliced into the first one's text
            # and neither would parse. `@implements A, B` is the spelling that
            # fits on the one line there is (felixefelip/steep#149).
            module_names = Array(spec["implements"]).map(&:to_s).reject(&:empty?)
            next [] if call_name.empty? || module_names.empty?

            implements = "# @implements #{module_names.join(", ")}"
            self_type = spec["self"].to_s
            self_annotation = self_type.empty? ? nil : "# @type self: #{self_type}"
            # Optional discriminator: the class/module the call is WRITTEN IN. A
            # name alone cannot tell two blocks apart, and one file can write the
            # same DSL call twice with a DIFFERENT target for each — a stored
            # block replayed onto one class here and another there. Without this
            # both entries land on both blocks, so a generator that cannot say
            # which is which has to decline and emit nothing at all.
            #
            # A LINE would be the obvious key and is the wrong one: `inject`
            # above may have added lines to this very source before we get here,
            # so a line measured against the real file no longer points at the
            # same call. The lexical scope survives any such rewrite.
            #
            # Absent, every call of that name matches, which is what a
            # single-block DSL (`class_methods do`) means and what every sidecar
            # written before this said.
            scope = spec["in"].to_s
            scope = nil if scope.empty?
            # The def the call is written inside, when it is not written in the
            # module body at all. See `find_block_calls`: it both admits a
            # receiver and keeps the match unique.
            method = spec["method"].to_s
            method = nil if method.empty?

            find_block_calls(result.value, call_name, scope, method).flat_map do |call|
              block = call.block
              next [] unless block.is_a?(Prism::BlockNode) && block.opening_loc

              block_annotation_insertions(source_code, block, implements, self_annotation)
            end
          end
          return source_code if insertions.empty?

          # Back to front so earlier byte offsets stay valid.
          insertions.sort_by { |i| -i[:offset] }.each_with_object(source_code.dup) do |i, out|
            out.replace(out.byteslice(0, i[:offset]) + i[:text] + out.byteslice(i[:offset]..))
          end
        rescue StandardError
          source_code
        end

        # Annotates individual methods of the module named `anchor`:
        # `defs` is `{ "method name" => "self type" }`, and each named method
        # gets `# @type self: <type>` on its signature line.
        #
        # Why per-def, when the entry already carries a module-wide
        # `@type instance:`: one line per module cannot answer a question whose
        # answer varies by method. A module extended by two classes has, as a
        # module, the union of both — but a method of it that only one of them
        # ever calls runs with that one as `self`, and the generator is what
        # knows which. Saying the union there is not wrong, it is unusable: the
        # generator types the call site with the narrow answer, and the body
        # then cannot pass its own `self` to it (felixefelip/rbs_infer#221).
        #
        # Same placement `inject_blocks` uses, and for the same reason: the
        # annotation rides the def's existing signature line, so it adds no
        # line and every reported line number stays aligned with the real file.
        # A method whose signature line has no room (an inline body) is skipped
        # rather than shifted, which also makes this idempotent.
        #
        # No blanket `rescue` here, unlike the two above. `Source.parse` runs on
        # every file of every driver, so an exception escaping it aborts the
        # check — which is what those rescues are guarding against. But the only
        # thing that can raise here is the SIDECAR being shaped wrong, and that
        # is checked for by name below, with a line in the log. Everything after
        # it walks a Prism parse of the very string it then slices, so anything
        # raising there is a bug in this file, and swallowing it would turn one
        # into "the annotation silently stopped being placed".
        def inject_defs(source_code, defs:, anchor:)
          return source_code if defs.nil?
          unless defs.is_a?(Hash)
            warn_malformed("`defs` for #{anchor} is #{defs.class}, expected a Hash")
            return source_code
          end
          return source_code if defs.empty?

          node = find_target_scope(source_code, anchor)
          return source_code unless node

          insertions = each_scope_def(node).filter_map do |defn|
            type = defs[defn.name.to_s]
            next if type.nil?
            # A non-String would be interpolated as its `inspect`-ish form and
            # land in the source as an unparseable annotation.
            unless type.is_a?(String) && !type.strip.empty?
              warn_malformed("self type for #{anchor}##{defn.name} is #{type.inspect}, expected a non-empty String")
              next
            end

            append_to_line(source_code, def_signature_end(defn), "# @type self: #{type}")
          end
          return source_code if insertions.empty?

          # Back to front so earlier byte offsets stay valid.
          insertions.sort_by { |i| -i[:offset] }.each_with_object(source_code.dup) do |i, out|
            out.replace(out.byteslice(0, i[:offset]) + i[:text] + out.byteslice(i[:offset]..))
          end
        end

        # Drops the memoized sidecar. The mtime check below makes this mostly
        # unnecessary, but rbs_infer can call it between stabilization passes
        # that rewrite the sidecar, mirroring its other Steep resets.
        def reset!
          @table = nil
          @table_key = nil
        end

        private

        # Memoized, invalidated by the sidecar's mtime so a regenerated sidecar
        # (between dependency levels) is picked up without an explicit reset.
        def load_table
          sidecar = Pathname(DEFAULT_SIDECAR_PATH)
          mtime = sidecar.file? ? sidecar.mtime : nil
          key = [sidecar.to_s, mtime]
          return @table if @table && @table_key == key

          @table_key = key
          @table = mtime ? parse(sidecar) : {}
        end

        def parse(sidecar)
          raw = YAML.safe_load(sidecar.read)
          raw.is_a?(Hash) ? raw : {}
        rescue Psych::Exception, SystemCallError => e
          Steep.logger.warn { "[module_self_types] failed to parse #{sidecar}: #{e.message}" } if defined?(Steep.logger)
          {}
        end

        # Same channel `parse` uses for a sidecar it cannot read: a malformed
        # sidecar is the user's to fix, so it is said out loud rather than
        # swallowed, and it does not stop the check.
        def warn_malformed(message)
          Steep.logger.warn { "[module_self_types] #{message}" } if defined?(Steep.logger)
        end

        def relative(path)
          prefix = "#{Dir.pwd}/"
          path.start_with?(prefix) ? path[prefix.length..] : path
        end

        # The innermost ModuleNode/ClassNode named `anchor`, or nil.
        def find_target_scope(source_code, anchor)
          result = Prism.parse(source_code)
          return nil unless result.success?

          found = nil
          best_depth = -1
          walk = lambda do |node, depth|
            return unless node.is_a?(Prism::Node)

            if node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ClassNode)
              cpath = node.constant_path
              name = cpath.respond_to?(:name) ? cpath.name.to_s : nil
              if name == anchor && depth > best_depth
                found = node
                best_depth = depth
              end
            end

            node.compact_child_nodes.each { |c| walk.call(c, depth + 1) }
          end
          walk.call(result.value, 0)
          found
        end

        # All `{ offset:, text: }` insertions for one annotated DSL block:
        #   * `# @implements <module>` on the block opener line; and
        #   * `# @type self: <type>` on each direct method-def line inside the
        #     block (only when a self type is given).
        # The opener `@implements` makes the block's `def`s attach to <module>;
        # the per-def `@type self:` widens each method body's self to the
        # including class's singleton so the includer's scopes/class methods
        # resolve there (a block-level self annotation does NOT reach into a
        # method body — its self comes from the method's owner). Every
        # annotation rides on an existing line, so nothing shifts; an
        # annotation that cannot ride its line (inline body, or already
        # present) is skipped — making this idempotent.
        def block_annotation_insertions(source_code, block, implements, self_annotation)
          insertions = []

          open_end = block.parameters&.location&.end_offset || block.opening_loc.end_offset
          insertions << append_to_line(source_code, open_end, implements)

          if self_annotation
            each_block_def(block) do |defn|
              insertions << append_to_line(source_code, def_signature_end(defn), self_annotation)
            end
          end

          insertions.compact
        end

        # A `{ offset:, text: }` that appends `annotation` to the source line
        # holding `offset`, when nothing but whitespace follows `offset` on that
        # line — so the comment adds no line and shifts nothing. Returns nil
        # when the rest of the line is non-blank (an inline body, or an
        # annotation already there), where a trailing `#` would swallow it.
        def append_to_line(source_code, offset, annotation)
          newline = source_code.byteindex("\n", offset) || source_code.bytesize
          tail = source_code.byteslice(offset, newline - offset) || ""
          return nil unless tail.strip.empty?

          { offset: offset, text: " #{annotation}" }
        end

        # The byte offset just past a def's signature — after the parameters
        # (`def foo(x)` / `def foo x`), else after the method name (`def foo`) —
        # where a trailing annotation can ride.
        def def_signature_end(node)
          node.rparen_loc&.end_offset || node.parameters&.location&.end_offset || node.name_loc.end_offset
        end

        # Yields each method definition that is a direct statement of `block`'s
        # body (the methods the `class_methods do` DSL contributes); nested
        # defs/classes have their own context and are left alone.
        def each_block_def(block)
          body = block.body
          return unless body.is_a?(Prism::StatementsNode)

          body.body.each do |stmt|
            yield stmt if stmt.is_a?(Prism::DefNode)
          end
        end

        # The INSTANCE methods a class/module node declares directly. A `def
        # self.x` is excluded: its `self` is the module object, which the
        # module-wide annotation already covers and which no invoker narrows.
        # Nested scopes have their own context and their own sidecar entry.
        def each_scope_def(node)
          body = node.body
          return [] unless body.is_a?(Prism::StatementsNode)

          body.body.select { |stmt| stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? }
        end

        # Every receiverless `call_name do … end` in the tree, optionally only
        # those written inside `scope` (a `::`-qualified class/module path, as
        # the enclosing declarations spell it lexically).
        #
        # `method` lifts the receiverless rule and replaces it: with it, the
        # call is looked for inside a `def` of that name, and may have any
        # receiver. That is the OTHER place a later-replayed block is written —
        # Ruby's own `included` hook, where the block is `base.class_eval do … end`
        # in the hook's body rather than a DSL call in the module body
        # (felixefelip/steep#147, felixefelip/rbs_infer#260).
        #
        # It is a discriminator as much as a permission. `class_eval` says
        # nothing about which block is meant — one module can write it in two
        # methods and replay each onto a different class — so lifting the
        # receiver rule without a way to tell those apart would land both
        # entries on both blocks, which is what `scope` exists to prevent one
        # level up.
        def find_block_calls(root, call_name, scope = nil, method = nil)
          target = call_name.to_sym
          wanted = scope && normalize_scope(scope)
          within = method&.to_sym
          found = []
          walk = lambda do |node, path, enclosing|
            return unless node.is_a?(Prism::Node)

            inner = scope_path(node, path)
            inner_def = node.is_a?(Prism::DefNode) ? node.name : enclosing
            if node.is_a?(Prism::CallNode) && node.name == target &&
               (within ? enclosing == within : node.receiver.nil?) &&
               node.block.is_a?(Prism::BlockNode) &&
               (wanted.nil? || wanted == path)
              found << node
            end
            node.compact_child_nodes.each { |c| walk.call(c, inner, inner_def) }
          end
          walk.call(root, nil, nil)
          found
        end

        # `path` extended by `node`'s own name when it opens a scope, else
        # unchanged. A declaration written qualified (`class A::B`) or absolute
        # (`class ::A`) names its own path outright.
        def scope_path(node, path)
          return path unless node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ClassNode)

          name = constant_path_source(node.constant_path)
          return path unless name

          return normalize_scope(name) if name.start_with?("::") || name.include?("::")

          [path, name].compact.join("::")
        end

        def constant_path_source(cpath)
          case cpath
          when Prism::ConstantReadNode then cpath.name.to_s
          when Prism::ConstantPathNode then cpath.slice
          end
        end

        # One spelling for a scope, so `::A::B` from the sidecar and `A::B` read
        # off the declarations compare equal.
        def normalize_scope(name)
          name.to_s.strip.delete_prefix("::")
        end

        # Inserts the lines, indented one level past the declaration, right
        # before the node's closing `end`.
        # Spliced in BYTES, because that is what Prism counts: a `start_offset`
        # measured in bytes indexed into a String is a character index, and one
        # multi-byte character anywhere above the anchor slides the insertion
        # point down — past the module's own `end` and into its parent's body,
        # where the annotation binds to the wrong scope and silently does
        # nothing. `inject_blocks` splices by byte for the same reason.
        def insert_in_body(source_code, node, annotation_lines)
          return append_at_end(source_code, annotation_lines) unless node.respond_to?(:end_keyword_loc) && node.end_keyword_loc

          indent = " " * (node.location.start_column + 2)
          block = annotation_lines.map { |line| "#{indent}#{line}\n" }.join
          bytes = source_code.b
          line_start = (bytes.rindex("\n".b, node.end_keyword_loc.start_offset) || -1) + 1

          (bytes[0...line_start] + block.b + bytes[line_start..]).force_encoding(source_code.encoding)
        end

        def append_at_end(source_code, annotation_lines)
          source_code.rstrip + "\n\n" + annotation_lines.join("\n") + "\n"
        end
      end
    end
  end
end

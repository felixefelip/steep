# frozen_string_literal: true

module Steep
  class Source
    # Appends `# @type self:` / `# @type instance:` annotations to module and
    # concern files at parse time, without touching files on disk.
    #
    # Mirrors the ErbSelfTypeResolver pattern: annotations are appended at the
    # END of the source (after the closing `end`), so original line numbers are
    # preserved and IDE error messages point to the correct lines.
    #
    # Rules:
    #   - ActiveSupport::Concern modules get both annotations appended:
    #       # @type self: singleton(Post) & singleton(Post::Notifiable)
    #       # @type instance: Post & Post::Notifiable
    #
    #   - Plain modules get only the instance annotation appended:
    #       # @type instance: Post & Post::Taggable
    #
    # Including class is resolved from the module's namespace:
    #   Post::Notifiable  → Post
    #   User::Recoverable → User
    #
    # For helpers and controller concerns the including class is always
    # ApplicationController (derived by Rails convention, not namespace).
    #
    # Idempotent: skips files that already contain the annotation for the module.
    module ModuleSelfTypeResolver
      MODELS_PREFIX = "app/models/"
      HELPERS_PREFIX = "app/helpers/"
      CONTROLLER_CONCERNS_PREFIX = "app/controllers/concerns/"

      class << self
        # Returns the annotated source_code, or the original if nothing to inject.
        def annotate(path, source_code)
          path_str = path.to_s
          return source_code unless path_str.end_with?(".rb")

          helpers_idx = path_str.index(HELPERS_PREFIX)
          return annotate_helper(path_str, source_code, helpers_idx) if helpers_idx

          controller_concerns_idx = path_str.index(CONTROLLER_CONCERNS_PREFIX)
          return annotate_controller_concern(path_str, source_code, controller_concerns_idx) if controller_concerns_idx

          idx = path_str.index(MODELS_PREFIX)
          return source_code unless idx

          relative = path_str[(idx + MODELS_PREFIX.length)..].delete_suffix(".rb")
          # Rails treats app/models/concerns/ as an autoload root (no namespace)
          relative = relative.delete_prefix("concerns/")
          module_name = relative.split("/").map { |s| camelize(s) }.join("::")
          return source_code if module_name.empty?

          parts = module_name.split("::")
          return source_code if parts.size < 2

          including_class = parts[0..-2].join("::")

          is_concern = source_code.include?("extend ActiveSupport::Concern")

          # Idempotency
          return source_code if source_code.match?(/@type (?:self|instance):.*#{Regexp.escape(module_name)}/)

          if is_concern
            append_concern_annotations(source_code, module_name, including_class)
          else
            append_module_annotation(source_code, module_name, including_class)
          end
        end

        private

        def annotate_controller_concern(path_str, source_code, idx)
          relative = path_str[(idx + CONTROLLER_CONCERNS_PREFIX.length)..].delete_suffix(".rb")
          module_name = relative.split("/").map { |s| camelize(s) }.join("::")
          return source_code if module_name.empty?

          including_class = "ApplicationController"

          # Idempotency
          return source_code if source_code.match?(/@type instance:.*#{Regexp.escape(module_name)}/)

          is_concern = source_code.include?("extend ActiveSupport::Concern")

          if is_concern
            append_concern_annotations(source_code, module_name, including_class)
          else
            append_module_annotation(source_code, module_name, including_class)
          end
        end

        def annotate_helper(path_str, source_code, idx)
          relative = path_str[(idx + HELPERS_PREFIX.length)..].delete_suffix(".rb")
          module_name = relative.split("/").map { |s| camelize(s) }.join("::")
          return source_code if module_name.empty?

          including_class = "ApplicationController"

          # Idempotency
          return source_code if source_code.match?(/@type instance:.*#{Regexp.escape(module_name)}/)

          is_concern = source_code.include?("extend ActiveSupport::Concern")

          if is_concern
            append_concern_annotations(source_code, module_name, including_class)
          else
            append_module_annotation(source_code, module_name, including_class)
          end
        end

        # Appends both @type self: and @type instance: at end of file (concern).
        # Mirrors ERB convention: source_code + "\n# @type self: ..."
        def append_concern_annotations(source_code, module_name, including_class)
          self_annotation     = "# @type self: singleton(#{including_class}) & singleton(#{module_name})"
          instance_annotation = "# @type instance: #{including_class} & #{module_name}"
          source_code.rstrip + "\n\n#{self_annotation}\n#{instance_annotation}\n"
        end

        # Appends @type instance: at end of file (plain module).
        def append_module_annotation(source_code, module_name, including_class)
          annotation = "# @type instance: #{including_class} & #{module_name}"
          source_code.rstrip + "\n\n#{annotation}\n"
        end

        def camelize(str)
          str.split(/[_-]/).map(&:capitalize).join
        end
      end
    end
  end
end

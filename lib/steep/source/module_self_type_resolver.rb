# frozen_string_literal: true

module Steep
  class Source
    # Injects `# @type self:` annotations into module and concern files at parse
    # time, without touching files on disk.
    #
    # Mirrors the ErbSelfTypeResolver pattern: when STEEP_MODULE_CONVENTION is
    # set, Steep calls `ModuleSelfTypeResolver.annotate(path, source_code)` and
    # the returned source is parsed instead of the original.
    #
    # Rules:
    #   - ActiveSupport::Concern modules get:
    #       # @type self: singleton(Post) & singleton(Post::Notifiable)
    #     (inserted after the `extend ActiveSupport::Concern` line)
    #
    #   - Plain modules get:
    #       # @type self: Post & Post::Notifiable
    #     (inserted after the `module ModuleName` line)
    #
    # Including class is resolved from the module's namespace:
    #   Post::Notifiable  → Post
    #   User::Recoverable → User
    #
    # Idempotent: skips files that already contain `@type self:` for the module.
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
            inject_after_extend(source_code, module_name, including_class)
          else
            inject_after_module_line(source_code, module_name, including_class)
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
            inject_after_extend(source_code, module_name, including_class)
          else
            inject_after_module_line(source_code, module_name, including_class)
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
            inject_after_extend(source_code, module_name, including_class)
          else
            inject_after_module_line(source_code, module_name, including_class)
          end
        end

        def inject_after_extend(source_code, module_name, including_class)
          self_annotation     = "# @type self: singleton(#{including_class}) & singleton(#{module_name})"
          instance_annotation = "# @type instance: #{including_class} & #{module_name}"

          lines = source_code.lines
          extend_idx = lines.index { |l| l.match?(/\bextend\s+ActiveSupport::Concern\b/) }
          return source_code unless extend_idx

          indent = lines[extend_idx].match(/\A(\s*)/)[1]
          lines.insert(extend_idx + 1, "\n", "#{indent}#{self_annotation}\n", "#{indent}#{instance_annotation}\n")
          lines.join
        end

        def inject_after_module_line(source_code, module_name, including_class)
          annotation = "# @type instance: #{including_class} & #{module_name}"

          lines = source_code.lines
          module_idx = lines.index { |l| l.match?(/\A\s*module\s+#{Regexp.escape(module_name)}\b/) }
          return source_code unless module_idx

          indent = lines[module_idx].match(/\A(\s*)/)[1] + "  "
          lines.insert(module_idx + 1, "#{indent}#{annotation}\n", "\n")
          lines.join
        end

        def camelize(str)
          str.split(/[_-]/).map(&:capitalize).join
        end
      end
    end
  end
end

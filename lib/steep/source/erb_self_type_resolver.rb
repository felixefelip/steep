# frozen_string_literal: true

module Steep
  class Source
    # Resolves the self type for ERB files based on Rails view path conventions.
    #
    # Maps view paths to ERB class names:
    #   app/views/posts/show.html.erb        → ERBPostsShow
    #   app/views/posts/_form.html.erb       → ERBPartialPostsForm
    #   app/views/layouts/application.html.erb → ERBLayoutsApplication
    #   app/views/admin/posts/show.html.erb  → ERBAdminPostsShow
    #   app/views/user_mailer/welcome.html.erb → ERBUserMailerWelcome
    module ErbSelfTypeResolver
      VIEW_PREFIX = "app/views/"

      class << self
        # Returns the ERB class name for a given path, or nil if not a Rails view.
        def resolve(path)
          path_str = path.to_s
          return nil unless path_str.end_with?(".erb")

          # Extract the app/views/ relative portion
          idx = path_str.index(VIEW_PREFIX)
          return nil unless idx

          view_relative = path_str[(idx + VIEW_PREFIX.length)..]
          return nil unless view_relative

          # Strip template extension (.html.erb, .turbo_stream.erb, etc.)
          view_relative = view_relative.sub(/\.(html|turbo_stream)\.erb\z/, "")

          parts = view_relative.split("/")
          filename = parts.pop
          return nil unless filename

          is_partial = filename.start_with?("_")
          filename = filename.delete_prefix("_") if is_partial

          segments = (parts + [filename]).map { |s| camelize(s) }
          prefix = is_partial ? "ERBPartial" : "ERB"

          "#{prefix}#{segments.join}"
        end

        private

        def camelize(str)
          str.split(/[_-]/).map(&:capitalize).join
        end
      end
    end
  end
end

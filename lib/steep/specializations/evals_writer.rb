module Steep
  module Specializations
    module Evals
      # `sig/generated/.steep_string_evals.yml`, keyed by the CALL SITE rather
      # than by the method and its argument tuple the way the specialization
      # sidecar is. The consumer rewrites a file it is holding, so the question
      # it asks is "what does the call on this line define", and a key it can
      # answer from the node in front of it saves it re-deriving a tuple
      # spelling that only Steep knows.
      #
      #     ---
      #     version: 1
      #     call_sites:
      #       app/models/article.rb:7:2:
      #       - |
      #         def content
      #           rich_text_content || build_rich_text_content
      #         end
      class Writer
        def self.write(path, call_sites)
          new(path, call_sites).write
        end

        def initialize(path, call_sites)
          @path = path
          @call_sites = call_sites
        end

        def write
          @path.parent.mkpath
          @path.write(YAML.dump(payload))
          @path
        end

        private

        def payload
          {
            "version" => SCHEMA_VERSION,
            "call_sites" => @call_sites.keys.sort.to_h { |key| [key, @call_sites[key].map { |chunk| entry(chunk) }] }
          }
        end

        # A chunk with no target stays a bare string — the version 1 spelling,
        # and still what an eval on the caller's own self writes, since only the
        # call site knows which class that is. One that NAMES its class says so,
        # which is the whole of version 2.
        def entry(chunk)
          return nil if chunk.nil?
          return chunk.source if chunk.target.nil?

          { "source" => chunk.source, "target" => chunk.target }
        end
      end
    end
  end
end

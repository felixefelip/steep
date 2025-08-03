module Steep
  class Project
    class Pattern
      attr_reader :patterns
      attr_reader :ignores
      attr_reader :prefixes
      attr_reader :ignore_prefixes
      attr_reader :exts

      def initialize(patterns:, ignores: [], exts:)
        @patterns = patterns
        @ignores = ignores
        @exts = exts

        @prefixes = patterns.map do |pat|
          if pat == "." || pat == "./"
            ""
          else
            pat.delete_prefix("./").delete_suffix(File::Separator) << File::Separator
          end
        end
        @ignore_prefixes = ignores.map do |pat|
          if pat == "." || pat == "./"
            ""
          else
            pat.delete_prefix("./").delete_suffix(File::Separator) << File::Separator
          end
        end
      end

      def =~(path)
        unless path.is_a?(Pathname)
          path = Pathname(path.to_s)
        end

        match?(path) && !ignore?(path)
      end

      def match?(path)
        test_string(path, patterns, prefixes)
      end

      def ignore?(path)
        test_string(path, ignores, ignore_prefixes)
      end

      def test_string(path, patterns, prefixes)
        string = path.to_s

        patterns.any? {|pat| File.fnmatch(pat, string, File::FNM_PATHNAME) } ||
          prefixes.any? {|prefix|
            exts.any? {|ext| File.fnmatch("#{prefix}**/*#{ext}", string, File::FNM_PATHNAME) }
          }
      end

      def empty?
        patterns.empty?
      end
    end
  end
end

module Steep
  module Specializations
    module Evals
      # Whether each string eval folded at every call site a run read it under,
      # by the eval's site (`TypeInference::ClassMemoAnalyzer.site`). One whose
      # every run is placed in the program as checked Ruby calls nothing a reader
      # of the program cannot see.
      class Folds
        def self.read(base_dir)
          path = base_dir + DEFAULT_OUTPUT_PATH
          return Set[] unless path.file?

          sites = YAML.safe_load(path.read)&.fetch("folded", nil)
          sites.is_a?(Array) ? sites.to_set { |site| File.expand_path(site, base_dir.to_s) } : Set[]
        rescue Psych::Exception
          Set[]
        end

        def initialize
          @folds = {} #: Hash[String, bool]
        end

        # @return the chunk
        def record(effect, chunk)
          site = effect.kind == :eval && TypeInference::ClassMemoAnalyzer.site(effect.node)
          @folds[site] = @folds.fetch(site, true) && !chunk.nil? if site
          chunk
        end

        # A frame a call site does not read: every eval its body makes runs
        # there with what the site passes, which is not placed.
        def unread(def_node)
          each_eval(def_node) { |site| @folds[site] = false }
          nil
        end

        def sites(base_dir)
          @folds.select { |_, folded| folded }.keys.map { |site| Pathname(site).relative_path_from(base_dir).to_s }
        end

        private

        def each_eval(node, &block)
          return unless node.is_a?(::Parser::AST::Node)

          if node.type == :send && TypeInference::ClassMemoAnalyzer::STRING_EVALS.include?(node.children[1])
            site = TypeInference::ClassMemoAnalyzer.site(node) and yield site
          end
          node.children.each { |child| each_eval(child, &block) }
        end
      end
    end
  end
end

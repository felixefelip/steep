# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module Project
      # Metrics/ClassLength and Metrics/ModuleLength with a per-file ceiling. A file
      # listed in `Ceilings` may keep its largest class (or module) at the recorded
      # size but not grow it, and when it shrinks the ceiling has to come down with
      # it — so the record never lags the code and the slack never comes back.
      #
      # Keyed by file rather than by name because a cop reads one file at a time: a
      # class reopened in a second file is a second, smaller node, and would read as
      # the class having shrunk.
      #
      #   Project/ClassLengthCeiling:
      #     Max: 400
      #     Ceilings:
      #       lib/steep/type_construction.rb: 3884
      module LengthCeiling
        SHRANK = "Largest %<kind>s shrank to %<length>d lines; lower this file's ceiling in .rubocop.yml from %<max>d."
        BACK_UNDER = "No %<kind>s here is over %<max>d lines any more; remove this file's ceiling from .rubocop.yml."

        def on_new_investigation
          super
          @largest = nil
        end

        def on_investigation_end
          report_stale_ceiling if ceiling && @largest
          super
        end

        private

        def check_code_length(node)
          return super unless ceiling

          length = build_code_length_calculator(node).calculate
          @largest = [length, node] if @largest.nil? || length > @largest.first
          add_offense(location(node), message: message(length, ceiling)) if length > ceiling
        end

        def report_stale_ceiling
          length, node = @largest
          if length <= max_length
            add_offense(location(node), message: format(BACK_UNDER, kind: kind, max: max_length))
          elsif length < ceiling
            add_offense(location(node), message: format(SHRANK, kind: kind, length: length, max: ceiling))
          end
        end

        def ceiling
          ceilings = cop_config.fetch("Ceilings", nil) || {}
          path = processed_source.file_path or return
          ceilings[PathUtil.smart_path(path)]
        end
      end

      class ClassLengthCeiling < Metrics::ClassLength
        include LengthCeiling

        private

        def kind = "class"
      end

      class ModuleLengthCeiling < Metrics::ModuleLength
        include LengthCeiling

        private

        def kind = "module"
      end
    end
  end
end

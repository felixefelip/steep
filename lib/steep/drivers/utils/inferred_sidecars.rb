module Steep
  module Drivers
    module Utils
      # The sidecars `steep check` infers and writes before it checks.
      class InferredSidecars
        attr_reader :stdout, :stderr

        def initialize(stdout:, stderr:)
          @stdout = stdout
          @stderr = stderr
        end

        # Postconditions first: contract enforcement observes call sites, and a
        # call site's satisfaction can depend on a postcondition establishment —
        # `x = build` importing `x.attr` non-nil so a later `x.save` satisfies
        # `requires self.attr` (felixefelip/steep#56).
        def run(project)
          postconditions(project)
          project.reload_postconditions!
          contracts_and_specializations(project)
          project.reload_specializations!
        end

        private

        # Neither phase reads what the other writes in this run, only what the
        # run before left: loading `project.contracts` before the fork keeps
        # specializations on that one, as they were when the phases ran in turn.
        def contracts_and_specializations(project)
          project.contracts
          unless Process.respond_to?(:fork)
            contracts(project)
            specializations(project)
            return
          end

          reader, writer = IO.pipe
          pid = fork do
            reader.close
            contracts(project, out: writer)
          ensure
            writer.close
            exit!(0)
          end
          writer.close
          contracts_output = Thread.new { reader.read }
          specializations_output = StringIO.new
          specializations(project, out: specializations_output)
          Process.wait(pid)
          stdout.print(contracts_output.value, specializations_output.string)
        end

        def postconditions(project)
          runner = Postconditions::Runner.new(project)
          entries = runner.run
          runner.write(entries)

          lines = entries.flat_map do |entry|
            ["#{entry.class_name}#{entry.singleton ? "." : "#"}#{entry.method_name}", *entry.ivars.map { |name, type| "  #{name}: #{type}" }]
          end
          print_inferred("Inferred postconditions (ivar refinements)", lines, project.relative_path(runner.output_path))
        rescue => e
          stderr.puts "Warning: postcondition inference failed: #{e.class}: #{e.message}"
        end

        def contracts(project, out: stdout)
          runner = Contracts::Runner.new(project)
          contracts = runner.run
          runner.write(contracts)

          lines = contracts.map { |contract| "#{contract.type_name}#{contract.singleton ? "." : "#"}#{contract.method_name}" }
          print_inferred("Inferred preconditions", lines, project.relative_path(runner.output_path), out: out)
        rescue => e
          stderr.puts "Warning: precondition inference failed: #{e.class}: #{e.message}"
        end

        def specializations(project, out: stdout)
          runner = Specializations::Runner.new(project)
          methods = runner.run
          runner.write(methods)

          tuples = methods.flat_map { |key, entries| entries.each_key.map { |arguments| "#{key}#{arguments}" } }
          print_inferred("Inferred specializations (return types per argument tuple)", tuples, project.relative_path(runner.output_path), out: out)
          print_inferred("Inferred string evals (code a call site writes)", runner.evals.keys, project.relative_path(runner.evals_output_path), out: out)
          print_inferred("Receivers typed but not recorded (taken as untyped)", runner.unrecorded_receivers.map { |site, type| "#{site}  #{type}" }, out: out)
        rescue => e
          stderr.puts "Warning: specialization inference failed: #{e.class}: #{e.message}"
        end

        def print_inferred(title, lines, path = nil, out: stdout)
          return if lines.empty?

          out.puts Rainbow("# #{title}:").bold
          lines.each { |line| out.puts "  #{line}" }
          out.puts "  → #{path}" if path
          out.puts
        end
      end
    end
  end
end

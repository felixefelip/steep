module Steep
  module Drivers
    class ContractsInfer
      attr_reader :stdout, :stderr

      include Utils::DriverHelper

      def initialize(stdout:, stderr:)
        @stdout = stdout
        @stderr = stderr
      end

      def run
        project = load_config
        runner = Contracts::Runner.new(project)
        contracts = runner.run

        runner.write(contracts)
        relative = project.relative_path(runner.output_path)

        if contracts.empty?
          stdout.puts "Inferred 0 preconditions; #{relative} not written."
        else
          stdout.puts "Inferred #{contracts.size} method preconditions:"
          contracts.each do |contract|
            stdout.puts "  #{format_key(contract)}"
            contract.requires.each do |req|
              stdout.puts "    - #{format_predicate(req)}"
            end
          end
          stdout.puts
          stdout.puts "Sidecar written to: #{relative}"
        end

        0
      end

      private

      def format_key(contract)
        sep = contract.singleton ? "." : "#"
        "#{contract.type_name}#{sep}#{contract.method_name}"
      end

      def format_predicate(predicate)
        case predicate
        when Contracts::Predicate::NotNil
          "not_nil(#{format_expr(predicate.expr)})"
        end
      end

      def format_expr(expr)
        case expr
        when Contracts::Expr::SelfRef
          "self"
        when Contracts::Expr::Send
          base = "#{format_expr(expr.receiver)}.#{expr.method}"
          expr.chain.empty? ? base : "#{base}.#{expr.chain.join('.')}"
        end
      end
    end
  end
end

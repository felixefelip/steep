module Steep
  module Drivers
    module Utils
      module DriverHelper
        attr_accessor :steepfile
        attr_accessor :disable_install_collection

        def load_config(path: steepfile || Pathname("Steepfile"))
          if path.file?
            steep_file_path = path.absolute? ? path : Pathname.pwd + path
            Project.new(steepfile_path: steep_file_path).tap do |project|
              Project::DSL.parse(project, path.read, filename: path.to_s)
            end
          else
            Steep.ui_logger.error { "Cannot find a configuration at #{path}: `steep init` to scaffold. Using current directory..." }
            Project.new(steepfile_path: nil, base_dir: Pathname.pwd).tap do |project|
              Project::DSL.eval(project) do
                target :'.' do
                  check '.'
                  signature '.'
                end
              end
            end
          end.tap do |project|
            project.targets.each do |target|
              case result = target.options.load_collection_lock
              when nil, RBS::Collection::Config::Lockfile
                # ok
              when Pathname
                # File is missing
                if result == target.options.collection_config_path
                  # Config file is missing
                  Steep.ui_logger.error { "rbs-collection configuration is missing: `#{result}`" }
                else
                  # Lockfile is missing
                  Steep.ui_logger.error { "Run `rbs collection install` to generate missing lockfile: `#{result}`" }
                end
              when YAML::SyntaxError
                # File is broken
                Steep.ui_logger.error { "rbs-collection setup is broken:\nsyntax error #{result.inspect}" }
              when RBS::Collection::Config::CollectionNotAvailable
                unless disable_install_collection
                  install_collection(target, target.options.collection_config_path || raise)
                else
                  Steep.ui_logger.error { "Run `rbs collection install` to set up RBS files for gems" }
                end
              end
            end
          end
        end

        def install_collection(target, config_path)
          Steep.ui_logger.info { "Installing RBS files for collection: #{config_path}" }
          lockfile_path = RBS::Collection::Config.to_lockfile_path(config_path)
          io = StringIO.new
          begin
            RBS::Collection::Installer.new(lockfile_path: lockfile_path, stdout: io).install_from_lockfile()
            target.options.load_collection_lock(force: true)
            Steep.ui_logger.debug { "Finished setting up RBS collection: " + io.string }

            result = target.options.load_collection_lock(force: true)
            unless result.is_a?(RBS::Collection::Config::Lockfile)
              raise "Failed to set up RBS collection: #{result.inspect}"
            end
          rescue => exn
            Steep.ui_logger.error { "Failed to set up RBS collection: #{exn.inspect}" }
          end
        end

        def request_id
          SecureRandom.alphanumeric(10)
        end

        def wait_for_response_id(reader:, id:, unknown_responses: nil, &block)
          reader.read do |message|
            Steep.logger.debug { "Received message waiting for #{id}: #{message.inspect}" }

            response_id = message[:id]

            if response_id == id
              return message
            end

            if block
              yield message
            else
              case unknown_responses
              when :ignore, nil
                # nop
              when :log
                Steep.logger.error { "Unexpected message: #{message.inspect}" }
              when :raise
                raise "Unexpected message: #{message.inspect}"
              end
            end
          end
        end

        def shutdown_exit(writer:, reader:)
          request_id().tap do |id|
            writer.write({ method: :shutdown, id: id })
            wait_for_response_id(reader: reader, id: id)
          end
          writer.write({ method: :exit })
        end

        def wait_for_message(reader:, unknown_messages: :ignore, &block)
          reader.read do |message|
            if yield(message)
              return message
            else
              case unknown_messages
              when :ignore
                # nop
              when :log
                Steep.logger.error { "Unexpected message: #{message.inspect}" }
              when :raise
                raise "Unexpected message: #{message.inspect}"
              end
            end
          end
        end

        def keep_diagnostic?(diagnostic, severity_level:)
          severity = diagnostic[:severity]

          case severity_level
          when nil, :hint
            true
          when :error
            severity <= LanguageServer::Protocol::Constant::DiagnosticSeverity::ERROR
          when :warning
            severity <= LanguageServer::Protocol::Constant::DiagnosticSeverity::WARNING
          when :information
            severity <= LanguageServer::Protocol::Constant::DiagnosticSeverity::INFORMATION
          end
        end

        # Call this immediately before forking the workers.
        #
        # The workers inherit the forking process's heap — and by then the two
        # inference passes both `check` and `langserver` run have left that heap large
        # and fragmented. Fragmentation is what makes it expensive: a page holding a
        # few live objects among the dead gets dirtied by the worker's own GC, and
        # copy-on-write turns nearly the whole heap private, per worker.
        #
        # Compacting first packs the live objects — the parsed RBS environment above
        # all — into far fewer pages, which the workers then READ without copying.
        # Measured on a ~1400-file project with 10 workers: 12.1 GiB of unique memory
        # across the tree became 3.7 GiB, and the run got slightly faster for no longer
        # swapping.
        #
        # Note this is the opposite of freeing the environment before forking: the
        # workers WANT to inherit it. Forking from a lean process instead measured
        # WORSE (6.4 GiB), because then each worker loads its own private copy.
        def compact_heap_before_fork
          GC.start(full_mark: true, immediate_sweep: true)
          GC.compact
          malloc_trim
        end

        # Returns the freed pages to the OS. glibc-only and reached through Fiddle, so
        # both the platform and the library are optional — the compaction above is what
        # matters, and it has already happened.
        def malloc_trim
          return unless load_fiddle

          libc = Fiddle.dlopen(nil)
          Fiddle::Function.new(libc["malloc_trim"], [Fiddle::TYPE_SIZE_T], Fiddle::TYPE_INT).call(0)
        rescue Fiddle::DLError
          Steep.logger.debug { "malloc_trim is unavailable on this platform" }
        end

        # Fiddle stopped being a default gem in Ruby 4.0, where requiring it warns even
        # when it does resolve. Neither the warning nor a failure is worth surfacing for
        # an optional optimization, so keep both quiet.
        def load_fiddle
          verbose = $VERBOSE
          $VERBOSE = nil
          require "fiddle"
          true
        rescue LoadError
          Steep.logger.debug { "Fiddle is unavailable; skipped returning freed pages to the OS" }
          false
        ensure
          $VERBOSE = verbose
        end

        (DEFAULT_CLI_LSP_INITIALIZE_PARAMS = {}).freeze
      end
    end
  end
end

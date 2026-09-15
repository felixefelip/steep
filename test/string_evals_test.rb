require_relative "test_helper"

class StringEvalsTest < Minitest::Test
  include TestHelper
  include ShellHelper

  Specializations = Steep::Specializations
  Project = Steep::Project

  def dirs
    @dirs ||= []
  end

  def write(relative, content)
    path = current_dir + relative
    path.parent.mkpath
    path.write(content)
    path
  end

  def setup_project(steepfile: STEEPFILE)
    write("Steepfile", steepfile)
    project = Project.new(steepfile_path: current_dir + "Steepfile")
    Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
    project
  end

  STEEPFILE = <<~STEEPFILE
    target :app do
      signature "sig"
      check "app"
    end
  STEEPFILE

  MACRO_RBS = <<~RBS
    class Base
      def self.has_rich_text: (Symbol name, ?store_if_blank: bool) -> untyped
    end

    class Article < Base
    end

    class Photo < Base
    end
  RBS

  def evals_of(project)
    runner = Specializations::Runner.new(project)
    runner.run
    runner.evals
  end

  def test_records_the_source_one_call_site_writes
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            class_eval "def \#{name}; rich_text_\#{name}; end"
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_equal(
        { "app/base.rb:8:2" => ["def content; rich_text_content; end"] },
        evals_of(setup_project)
      )
    end
  end

  def test_each_call_site_gets_its_own_source
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            class_eval "def \#{name}; end"
          end
        end

        class Article < Base
          has_rich_text :content
        end

        class Photo < Base
          has_rich_text :caption
        end
      RUBY

      evals = evals_of(setup_project)

      assert_equal ["def content; end"], evals.fetch("app/base.rb:8:2")
      assert_equal ["def caption; end"], evals.fetch("app/base.rb:12:2")
    end
  end

  # The heredoc is what the idiom is actually written with, and it is one `dstr`
  # like any other once the parameter carries the call site's literal.
  def test_records_a_heredoc_with_several_interpolations
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            class_eval <<-CODE
              def \#{name}
                rich_text_\#{name} || build_rich_text_\#{name}
              end
            CODE
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_equal(
        [<<~CODE.gsub(/^/, "      ")],
          def content
            rich_text_content || build_rich_text_content
          end
        CODE
        evals_of(setup_project).fetch("app/base.rb:12:2")
      )
    end
  end

  # The branch the call site does not take defines nothing there, and a checker
  # that narrows the condition is what says which one that is.
  def test_a_branch_the_call_site_does_not_take_is_not_recorded
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name, store_if_blank: true)
            if store_if_blank
              class_eval "def \#{name}=(v); end"
            else
              class_eval "def \#{name}_maybe=(v); end"
            end
          end
        end

        class Article < Base
          has_rich_text :content, store_if_blank: false
        end
      RUBY

      assert_equal ["def content_maybe=(v); end"], evals_of(setup_project).fetch("app/base.rb:12:2")
    end
  end

  # A call that omits an optional keyword still fixes it: the body runs with the
  # default, so the branch the default selects is the one this call site defines.
  def test_an_omitted_keyword_is_fixed_to_its_default
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name, store_if_blank: true)
            if store_if_blank
              class_eval "def \#{name}=(v); end"
            else
              class_eval "def \#{name}_maybe=(v); end"
            end
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_equal ["def content=(v); end"], evals_of(setup_project).fetch("app/base.rb:12:2")
    end
  end

  def test_a_case_is_decided_the_same_way
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            case name
            when :content then class_eval "def content_only; end"
            else class_eval "def other_only; end"
            end
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_equal ["def content_only; end"], evals_of(setup_project).fetch("app/base.rb:11:2")
    end
  end

  # A value the call site does not fix is reported as a hole rather than left
  # out: a consumer rendering these has to know it was handed part of a macro.
  def test_an_eval_whose_value_is_not_fixed_is_recorded_as_nil
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          def self.has_rich_text: (Symbol name) -> untyped
          def self.suffix: () -> String
        end

        class Article < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            class_eval "def \#{name}; end"
            class_eval "def \#{name}_\#{suffix}; end"
          end

          def self.suffix
            "ro"
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_equal ["def content; end", nil], evals_of(setup_project).fetch("app/base.rb:13:2")
    end
  end

  def test_module_eval_is_read_the_same_way
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            module_eval "def \#{name}; end"
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_equal ["def content; end"], evals_of(setup_project).fetch("app/base.rb:8:2")
    end
  end

  # `X.class_eval` and `class_eval do … end` are plain Ruby a reader already
  # sees; only the string form has nothing to read until a call site supplies it.
  def test_an_explicit_self_receiver_is_the_same_call
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            self.class_eval "def \#{name}; rich_text_\#{name}; end"
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_equal(
        { "app/base.rb:8:2" => ["def content; rich_text_content; end"] },
        evals_of(setup_project)
      )
    end
  end

  def test_a_block_or_a_receiver_is_not_read
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            Article.class_eval "def \#{name}; end"
            class_eval do
              def other; end
            end
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_empty evals_of(setup_project)
    end
  end

  # The S5b boundary of felixefelip/steep#171: `owner` is the caller's self, but
  # saying so needs the frame that passed it, and nothing here reads that yet.
  def test_a_receiver_that_is_not_self_is_not_read
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        module Writer
          def self.generate: (untyped owner, Symbol name) -> void
        end

        class Base
          def self.has_rich_text: (Symbol name) -> untyped
        end

        class Article < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        module Writer
          def self.generate(owner, name)
            owner.module_eval "def \#{name}; end"
          end
        end

        class Base
          def self.has_rich_text(name)
            Writer.generate(self, name)
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_empty evals_of(setup_project)
    end
  end

  def test_a_call_whose_argument_is_not_fixed_records_a_hole
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          def self.has_rich_text: (Symbol name) -> untyped
          def self.chosen: () -> Symbol
        end

        class Article < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            class_eval "def \#{name}; end"
          end

          def self.chosen
            :content
          end
        end

        class Article < Base
          has_rich_text chosen
        end
      RUBY

      assert_equal [nil], evals_of(setup_project).fetch("app/base.rb:12:2")
    end
  end

  # The failure the whole idea has to avoid: with the condition still open both
  # branches fold, and a consumer handed both writes a class two methods where
  # runtime has one. Neither is claimed.
  def test_a_condition_the_call_site_does_not_decide_records_holes
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          def self.slot: (Symbol name, ?writable: bool) -> untyped
          def self.dynamic: () -> bool
        end

        class Article < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.slot(name, writable: true)
            if writable
              class_eval "def \#{name}_rw; end"
            else
              class_eval "def \#{name}_ro; end"
            end
          end

          def self.dynamic
            true
          end
        end

        class Article < Base
          slot :size, writable: dynamic
        end
      RUBY

      assert_equal [nil, nil], evals_of(setup_project).fetch("app/base.rb:16:2")
    end
  end

  # A `case` branch runs only when every other one is dead. Two live branches
  # decide nothing, however many of the rest the checker ruled out.
  def test_a_case_with_two_live_branches_records_holes
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          def self.slot: (Symbol name, Symbol mode) -> untyped
          def self.mode: () -> Symbol
        end

        class Article < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.slot(name, mode)
            case mode
            when :ro then class_eval "def \#{name}_ro; end"
            when :rw then class_eval "def \#{name}_rw; end"
            end
          end

          def self.mode
            :ro
          end
        end

        class Article < Base
          slot :size, mode
        end
      RUBY

      assert_equal [nil, nil], evals_of(setup_project).fetch("app/base.rb:15:2")
    end
  end

  # A lambda the macro returns writes nothing until something calls it, and
  # nothing here knows whether anything does.
  def test_a_body_the_call_does_not_run_is_not_read
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            class_eval "def \#{name}_now; end"
            -> { class_eval "def \#{name}_never; end" }
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      assert_equal ["def content_now; end"], evals_of(setup_project).fetch("app/base.rb:9:2")
    end
  end

  # A macro taking no arguments fixes everything it has, so there is nothing for
  # the literal gate on RETURN specialization to say about it.
  def test_a_call_with_no_arguments_is_read
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          def self.install: () -> untyped
        end

        class Article < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.install
            class_eval "def installed; end"
          end
        end

        class Article < Base
          install
        end
      RUBY

      assert_equal ["def installed; end"], evals_of(setup_project).fetch("app/base.rb:8:2")
    end
  end

  # And a call that passes nothing still takes its defaults, which is enough to
  # decide a branch on its own.
  def test_a_default_alone_decides_a_branch
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          def self.slot: (?writable: bool) -> untyped
        end

        class Article < Base
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.slot(writable: false)
            if writable
              class_eval "def size_rw; end"
            else
              class_eval "def size_ro; end"
            end
          end
        end

        class Article < Base
          slot
        end
      RUBY

      assert_equal ["def size_ro; end"], evals_of(setup_project).fetch("app/base.rb:12:2")
    end
  end

  # `class_methods do … end` puts the def lexically in the concern and the
  # methods on its `ClassMethods`. `@implements`, injected from the module
  # self-type sidecar, is what says so — without reading it the def is keyed
  # under a name no call site ever resolves to, and the body is never
  # specialized.
  def test_a_def_inside_an_implementing_block_is_keyed_by_that_module
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        module Attribute
          def self.class_methods: () { () -> void } -> void

          module ClassMethods
            def has_rich_text: (Symbol name) -> untyped
          end
        end

        class Article
          extend Attribute::ClassMethods
        end
      RBS
      write("app/base.rb", <<~RUBY)
        module Attribute
          def self.class_methods(&block)
          end

          class_methods do # @implements ::Attribute::ClassMethods
            def has_rich_text(name) # @type self: singleton(::Article) & ::Attribute::ClassMethods
              class_eval "def \#{name}; end"
            end
          end
        end

        class Article
          has_rich_text :content
        end
      RUBY

      assert_equal ["def content; end"], evals_of(setup_project).fetch("app/base.rb:13:2")
    end
  end

  def test_write_drops_a_stale_sidecar
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", "class Base\nend\n")
      path = write("sig/generated/.steep_string_evals.yml", "---\nversion: 1\ncall_sites: {}\n")

      project = setup_project
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)

      refute_predicate path, :file?
    end
  end

  def test_write_emits_the_sidecar
    in_tmpdir do
      write("sig/base.rbs", MACRO_RBS)
      write("app/base.rb", <<~RUBY)
        class Base
          def self.has_rich_text(name)
            class_eval "def \#{name}; end"
          end
        end

        class Article < Base
          has_rich_text :content
        end
      RUBY

      project = setup_project
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)

      assert_equal(
        { "version" => 1, "call_sites" => { "app/base.rb:8:2" => ["def content; end"] } },
        YAML.safe_load(runner.evals_output_path.read)
      )
    end
  end
end

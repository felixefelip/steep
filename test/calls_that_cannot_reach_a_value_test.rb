require_relative "test_helper"
require_relative "specializations_project_helper"

class CallsThatCannotReachAValueTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def locals_rbs(name, put)
    <<~RBS
      class #{name}
        @locals: Hash[Symbol, K]?
        def read_#{put}: (Symbol key) -> K?
        def #{put}: (Symbol key, K value) -> K
      end
      module Hold#{name}
        @@locals: #{name}?
        def self.locals: () -> #{name}
      end
    RBS
  end

  def locals_ruby(name, put)
    <<~RUBY
      class #{name}
        def read_#{put}(key)
          locals = @locals
          locals ? locals[key] : nil
        end

        def #{put}(key, value)
          (@locals ||= {})[key] = value
        end
      end

      module Hold#{name}
        def self.locals = @@locals ||= #{name}.allocate
      end
    RUBY
  end

  def types
    in_tmpdir do
      write("sig/p.rbs", <<~RBS)
        class K
        end
        #{locals_rbs("SelfLocals", "put_self")}
        #{locals_rbs("VarLocals", "put_var")}
        #{locals_rbs("AliasedLocals", "put_aliased")}
        #{locals_rbs("KeywordLocals", "put_keyword")}
        #{locals_rbs("HeirLocals", "put_heir")}
        #{locals_rbs("ForeignLocals", "put_foreign")}
        class Filled[T]
          def put_self: (Symbol key, T value) -> T
          def fill: (Hash[Symbol, T] hash) -> self
        end
        class Passing[T]
          def pass: (T target, K value) -> untyped
        end
        class Copying
          def put_aliased: (Symbol key, K value) -> K
          def stored: (Symbol key, K value) -> K
          def put_keyword: (Symbol key, K value) -> K
          def kept: (Symbol key, K value) -> K
        end
        class Heir < HeirLocals
          def stored_by_heir: (Symbol key, K value) -> K
        end
        class Foreign
        end
        class P
          def on_generic_self: () -> untyped
          def on_type_variable: () -> untyped
          def alias_method_elsewhere: () -> untyped
          def alias_elsewhere: () -> untyped
          def alias_in_a_subclass: () -> untyped
          def alias_on_another_receiver: () -> untyped
        end
      RBS
      write("app/p.rb", <<~RUBY)
        class K
        end
        #{locals_ruby("SelfLocals", "put_self")}
        #{locals_ruby("VarLocals", "put_var")}
        #{locals_ruby("AliasedLocals", "put_aliased")}
        #{locals_ruby("KeywordLocals", "put_keyword")}
        #{locals_ruby("HeirLocals", "put_heir")}
        #{locals_ruby("ForeignLocals", "put_foreign")}

        class Filled
          def put_self(key, value) = value

          def fill(hash)
            hash.each_pair { |key, value| self.put_self(key, value) }
            self
          end
        end

        class Passing
          def pass(target, value) = target.put_var(:k, value)
        end

        class Copying
          def put_aliased(key, value) = value
          alias_method :stored, :put_aliased

          def put_keyword(key, value) = value
          alias kept put_keyword
        end

        class Heir < HeirLocals
          alias_method :stored_by_heir, :put_heir
        end

        class Foreign
        end
        Foreign.alias_method :stored_by_foreign, :put_foreign

        class P
          def on_generic_self = HoldSelfLocals.locals.read_put_self(:k)
          def on_type_variable = HoldVarLocals.locals.read_put_var(:k)
          def alias_method_elsewhere = HoldAliasedLocals.locals.read_put_aliased(:k)
          def alias_elsewhere = HoldKeywordLocals.locals.read_put_keyword(:k)
          def alias_in_a_subclass = HoldHeirLocals.locals.read_put_heir(:k)
          def alias_on_another_receiver = HoldForeignLocals.locals.read_put_foreign(:k)
        end

        Filled.new.fill({ k: K.new })
        Passing.new.pass(HoldVarLocals.locals, K.new)
      RUBY
      project = setup_project
      postconditions = Steep::Postconditions::Runner.new(project)
      postconditions.write(postconditions.run)
      project = setup_project
      runner = Steep::Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!
      return body_types(project, current_dir + "app/p.rb")
    end
  end

  def test_a_call_on_a_generic_self_reaches_no_value_of_another_class
    assert_equal "nil", types.fetch("on_generic_self")
  end

  def test_a_call_on_a_type_variable_may_reach_a_value_of_any_class
    assert_equal "(::K | nil)", types.fetch("on_type_variable")
  end

  def test_an_alias_written_in_another_class_reaches_no_value_of_this_one
    found = types

    assert_equal "nil", found.fetch("alias_method_elsewhere")
    assert_equal "nil", found.fetch("alias_elsewhere")
  end

  def test_an_alias_written_in_a_subclass_may_run_on_a_value_of_this_class
    assert_equal "(::K | nil)", types.fetch("alias_in_a_subclass")
  end

  def test_an_alias_made_on_another_receiver_is_still_taken_to_reach_any_value
    assert_equal "(::K | nil)", types.fetch("alias_on_another_receiver")
  end
end

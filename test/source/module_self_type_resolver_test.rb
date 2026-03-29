require_relative "../test_helper"

class Steep::Source::ModuleSelfTypeResolverTest < Minitest::Test
  Resolver = Steep::Source::ModuleSelfTypeResolver

  # --- concern with namespace ---

  def test_concern_injects_self_and_instance
    source = <<~RUBY
      module Post::Notifiable
        extend ActiveSupport::Concern

        included do
        end
      end
    RUBY

    result = Resolver.annotate("app/models/post/notifiable.rb", source)

    assert_includes result, "# @type self: singleton(Post) & singleton(Post::Notifiable)"
    assert_includes result, "# @type instance: Post & Post::Notifiable"
  end

  def test_concern_annotations_inserted_after_extend_line
    source = <<~RUBY
      module Post::Notifiable
        extend ActiveSupport::Concern

        included do
        end
      end
    RUBY

    result = Resolver.annotate("app/models/post/notifiable.rb", source)
    lines = result.lines

    extend_idx = lines.index { |l| l.include?("extend ActiveSupport::Concern") }
    self_idx     = lines.index { |l| l.include?("@type self:") }
    instance_idx = lines.index { |l| l.include?("@type instance:") }

    assert self_idx > extend_idx
    assert instance_idx > extend_idx
  end

  # --- plain module with namespace ---

  def test_plain_module_injects_only_instance
    source = <<~RUBY
      module Post::Taggable
        def tag_names
          tags.map(&:name)
        end
      end
    RUBY

    result = Resolver.annotate("app/models/post/taggable.rb", source)

    assert_includes result, "# @type instance: Post & Post::Taggable"
    refute_includes result, "@type self:"
  end

  def test_plain_module_annotation_inserted_after_module_line
    source = <<~RUBY
      module Post::Taggable
        def tag_names
        end
      end
    RUBY

    result = Resolver.annotate("app/models/post/taggable.rb", source)
    lines = result.lines

    module_idx   = lines.index { |l| l.include?("module Post::Taggable") }
    instance_idx = lines.index { |l| l.include?("@type instance:") }

    assert instance_idx == module_idx + 1
  end

  # --- idempotency ---

  def test_already_annotated_concern_is_unchanged
    source = <<~RUBY
      module Post::Notifiable
        extend ActiveSupport::Concern

        # @type self: singleton(Post) & singleton(Post::Notifiable)
        # @type instance: Post & Post::Notifiable

        included do
        end
      end
    RUBY

    result = Resolver.annotate("app/models/post/notifiable.rb", source)

    assert_equal source, result
  end

  def test_already_annotated_plain_module_is_unchanged
    source = <<~RUBY
      module Post::Taggable
        # @type instance: Post & Post::Taggable

        def tag_names
        end
      end
    RUBY

    result = Resolver.annotate("app/models/post/taggable.rb", source)

    assert_equal source, result
  end

  # --- files outside app/models/ and app/helpers/ ---

  def test_non_models_non_helpers_file_is_unchanged
    source = <<~RUBY
      module SomeModule
        def help; end
      end
    RUBY

    result = Resolver.annotate("lib/some_module.rb", source)

    assert_equal source, result
  end

  # --- app/helpers/ ---

  def test_helper_injects_instance_annotation
    source = <<~RUBY
      module PostsHelper
        def post_status_badge(post)
        end
      end
    RUBY

    result = Resolver.annotate("app/helpers/posts_helper.rb", source)

    assert_includes result, "# @type instance: ApplicationController & PostsHelper"
    refute_includes result, "@type self:"
  end

  def test_helper_annotation_inserted_after_module_line
    source = <<~RUBY
      module PostsHelper
        def post_status_badge(post)
        end
      end
    RUBY

    result = Resolver.annotate("app/helpers/posts_helper.rb", source)
    lines = result.lines

    module_idx   = lines.index { |l| l.include?("module PostsHelper") }
    instance_idx = lines.index { |l| l.include?("@type instance:") }

    assert instance_idx == module_idx + 1
  end

  def test_application_helper_injects_instance_annotation
    source = <<~RUBY
      module ApplicationHelper
        def current_year
          Time.current.year
        end
      end
    RUBY

    result = Resolver.annotate("app/helpers/application_helper.rb", source)

    assert_includes result, "# @type instance: ApplicationController & ApplicationHelper"
  end

  def test_helper_concern_injects_self_and_instance
    source = <<~RUBY
      module PostsHelper
        extend ActiveSupport::Concern

        included do
        end
      end
    RUBY

    result = Resolver.annotate("app/helpers/posts_helper.rb", source)

    assert_includes result, "# @type self: singleton(ApplicationController) & singleton(PostsHelper)"
    assert_includes result, "# @type instance: ApplicationController & PostsHelper"
  end

  def test_already_annotated_helper_is_unchanged
    source = <<~RUBY
      module PostsHelper
        # @type instance: ApplicationController & PostsHelper

        def post_status_badge(post)
        end
      end
    RUBY

    result = Resolver.annotate("app/helpers/posts_helper.rb", source)

    assert_equal source, result
  end

  def test_helper_full_absolute_path
    source = <<~RUBY
      module PostsHelper
        def help; end
      end
    RUBY

    result = Resolver.annotate("/home/user/myapp/app/helpers/posts_helper.rb", source)

    assert_includes result, "# @type instance: ApplicationController & PostsHelper"
  end

  def test_namespaced_helper
    source = <<~RUBY
      module Admin::PostsHelper
        def admin_badge(post)
        end
      end
    RUBY

    result = Resolver.annotate("app/helpers/admin/posts_helper.rb", source)

    assert_includes result, "# @type instance: ApplicationController & Admin::PostsHelper"
  end

  # --- module without namespace (Strategy B not yet supported) ---

  def test_unnamespaced_module_is_unchanged
    source = <<~RUBY
      module Taggable
        def tag_names
        end
      end
    RUBY

    result = Resolver.annotate("app/models/taggable.rb", source)

    assert_equal source, result
  end

  # --- full path ---

  def test_full_absolute_path
    source = <<~RUBY
      module Post::Notifiable
        extend ActiveSupport::Concern
      end
    RUBY

    result = Resolver.annotate("/home/user/myapp/app/models/post/notifiable.rb", source)

    assert_includes result, "# @type self: singleton(Post) & singleton(Post::Notifiable)"
    assert_includes result, "# @type instance: Post & Post::Notifiable"
  end

  def test_pathname_object
    source = <<~RUBY
      module Post::Notifiable
        extend ActiveSupport::Concern
      end
    RUBY

    result = Resolver.annotate(Pathname("app/models/post/notifiable.rb"), source)

    assert_includes result, "# @type self: singleton(Post) & singleton(Post::Notifiable)"
  end

  # --- indentation ---

  def test_concern_indentation_mirrors_extend_line
    source = "module Post::Notifiable\n  extend ActiveSupport::Concern\nend\n"

    result = Resolver.annotate("app/models/post/notifiable.rb", source)

    assert_includes result, "  # @type self:"
    assert_includes result, "  # @type instance:"
  end

  # --- app/models/concerns/ directory (Rails autoload root, no namespace) ---

  def test_concern_under_concerns_directory_strips_concerns_prefix
    source = <<~RUBY
      module Test::Filtrable
        extend ActiveSupport::Concern
      end
    RUBY

    result = Resolver.annotate("app/models/concerns/test/filtrable.rb", source)

    assert_includes result, "singleton(Test) & singleton(Test::Filtrable)"
    assert_includes result, "# @type instance: Test & Test::Filtrable"
    refute_includes result, "Concerns"
  end

  def test_concern_directly_under_concerns_directory
    source = <<~RUBY
      module Taggable
        extend ActiveSupport::Concern
      end
    RUBY

    # concerns/taggable.rb → module_name = "Taggable" → parts.size < 2 → skip
    result = Resolver.annotate("app/models/concerns/taggable.rb", source)

    assert_equal source, result
  end

  # --- snake_case to CamelCase conversion ---

  def test_snake_case_file_name_is_camelized
    source = <<~RUBY
      module User::PasswordRecoverable
        extend ActiveSupport::Concern
      end
    RUBY

    result = Resolver.annotate("app/models/user/password_recoverable.rb", source)

    assert_includes result, "singleton(User) & singleton(User::PasswordRecoverable)"
  end
end

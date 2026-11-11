require_relative "../test_helper"

class Steep::Source::ErbSelfTypeResolverTest < Minitest::Test
  Resolver = Steep::Source::ErbSelfTypeResolver

  def test_regular_view
    assert_equal "ERBPostsShow", Resolver.resolve("app/views/posts/show.html.erb")
  end

  def test_index_view
    assert_equal "ERBPostsIndex", Resolver.resolve("app/views/posts/index.html.erb")
  end

  def test_new_view
    assert_equal "ERBPostsNew", Resolver.resolve("app/views/posts/new.html.erb")
  end

  def test_edit_view
    assert_equal "ERBUsersEdit", Resolver.resolve("app/views/users/edit.html.erb")
  end

  def test_partial
    assert_equal "ERBPartialPostsForm", Resolver.resolve("app/views/posts/_form.html.erb")
  end

  def test_partial_in_shared
    assert_equal "ERBPartialSharedHeader", Resolver.resolve("app/views/shared/_header.html.erb")
  end

  def test_layout
    assert_equal "ERBLayoutsApplication", Resolver.resolve("app/views/layouts/application.html.erb")
  end

  def test_namespaced_controller
    assert_equal "ERBAdminPostsShow", Resolver.resolve("app/views/admin/posts/show.html.erb")
  end

  def test_namespaced_partial
    assert_equal "ERBPartialAdminPostsForm", Resolver.resolve("app/views/admin/posts/_form.html.erb")
  end

  def test_mailer
    assert_equal "ERBUserMailerWelcome", Resolver.resolve("app/views/user_mailer/welcome.html.erb")
  end

  def test_turbo_stream_erb
    assert_equal "ERBPostsCreate", Resolver.resolve("app/views/posts/create.turbo_stream.erb")
  end

  def test_full_path
    assert_equal "ERBPostsShow", Resolver.resolve("/home/user/myapp/app/views/posts/show.html.erb")
  end

  def test_pathname
    assert_equal "ERBPostsShow", Resolver.resolve(Pathname("app/views/posts/show.html.erb"))
  end

  def test_non_view_returns_nil
    assert_nil Resolver.resolve("app/controllers/posts_controller.rb")
  end

  def test_non_erb_returns_nil
    assert_nil Resolver.resolve("app/views/posts/show.html")
  end

  def test_no_app_views_returns_nil
    assert_nil Resolver.resolve("views/posts/show.html.erb")
  end
end

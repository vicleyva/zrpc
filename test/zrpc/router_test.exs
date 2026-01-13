defmodule Zrpc.RouterTest do
  use ExUnit.Case, async: true

  alias Zrpc.Context
  alias Zrpc.Router
  alias Zrpc.Router.{Alias, Entry}

  # Test procedure modules
  defmodule TestMiddleware.Logger do
    use Zrpc.Middleware

    @impl true
    def call(ctx, _opts, next) do
      next.(ctx)
    end
  end

  defmodule TestMiddleware.Auth do
    use Zrpc.Middleware

    @impl true
    def call(ctx, _opts, next) do
      ctx = Zrpc.Context.assign(ctx, :authed, true)
      next.(ctx)
    end
  end

  defmodule TestMiddleware.Admin do
    use Zrpc.Middleware

    @impl true
    def call(ctx, _opts, next) do
      ctx = Zrpc.Context.assign(ctx, :admin, true)
      next.(ctx)
    end
  end

  defmodule UserProcedures do
    use Zrpc.Procedure

    query :get do
      input Zoi.object(%{id: Zoi.string()})

      handler fn %{id: id}, ctx ->
        {:ok, %{id: id, name: "User #{id}", authed: ctx.assigns[:authed]}}
      end
    end

    query :list do
      handler fn _input, _ctx ->
        {:ok, [%{id: "1", name: "Alice"}, %{id: "2", name: "Bob"}]}
      end
    end

    mutation :create do
      input Zoi.object(%{name: Zoi.string()})

      handler fn %{name: name}, _ctx ->
        {:ok, %{id: "new-id", name: name}}
      end
    end
  end

  defmodule PostProcedures do
    use Zrpc.Procedure

    query :get do
      input Zoi.object(%{id: Zoi.string()})

      handler fn %{id: id}, _ctx ->
        {:ok, %{id: id, title: "Post #{id}"}}
      end
    end

    query :list do
      handler fn _input, _ctx ->
        {:ok, [%{id: "p1", title: "First Post"}]}
      end
    end
  end

  defmodule AdminProcedures do
    use Zrpc.Procedure

    query :stats do
      handler fn _input, ctx ->
        {:ok, %{admin: ctx.assigns[:admin], authed: ctx.assigns[:authed]}}
      end
    end

    mutation :delete_user do
      input Zoi.object(%{user_id: Zoi.string()})

      handler fn %{user_id: id}, _ctx ->
        {:ok, %{deleted: id}}
      end
    end
  end

  defmodule HealthProcedures do
    use Zrpc.Procedure

    query :check do
      handler fn _input, _ctx ->
        {:ok, %{status: "ok"}}
      end
    end
  end

  # Test routers
  defmodule SimpleRouter do
    use Zrpc.Router

    procedures Zrpc.RouterTest.UserProcedures, at: "users"
    procedures Zrpc.RouterTest.PostProcedures, at: "posts"
  end

  defmodule RouterWithMiddleware do
    use Zrpc.Router

    middleware TestMiddleware.Logger
    middleware TestMiddleware.Auth

    procedures UserProcedures, at: "users"
  end

  defmodule RouterWithScopes do
    use Zrpc.Router

    middleware TestMiddleware.Logger

    procedures UserProcedures, at: "users"

    scope "admin" do
      middleware TestMiddleware.Auth
      middleware TestMiddleware.Admin

      procedures AdminProcedures, at: "actions"

      scope "super" do
        procedures AdminProcedures, at: "super_actions"
      end
    end
  end

  defmodule RouterWithAliases do
    use Zrpc.Router

    procedures UserProcedures, at: "users"

    path_alias "users.get_user", to: "users.get"
    path_alias "getUser", to: "users.get", deprecated: true
  end

  defmodule RouterWithSkipMiddleware do
    use Zrpc.Router

    middleware TestMiddleware.Auth

    procedures UserProcedures, at: "users"
    procedures HealthProcedures, at: "health", skip_middleware: [TestMiddleware.Auth]
  end

  describe "Entry module" do
    test "build_path/1 creates dotted path from segments" do
      assert Entry.build_path([:users, :get_user]) == "users.get_user"
      assert Entry.build_path([:admin, :users, :list]) == "admin.users.list"
    end

    test "parse_path/1 splits path into segments" do
      assert Entry.parse_path("users.get_user") == [:users, :get_user]
      assert Entry.parse_path("admin.users.list") == [:admin, :users, :list]
    end

    test "valid_path?/1 validates path format" do
      assert Entry.valid_path?("users.get_user")
      assert Entry.valid_path?("admin.users.list_all")
      assert Entry.valid_path?("a123.b456")

      refute Entry.valid_path?("Users.Get")
      refute Entry.valid_path?("users..get")
      refute Entry.valid_path?(".users.get")
      refute Entry.valid_path?("users.get.")
      refute Entry.valid_path?("123.abc")
    end
  end

  describe "Alias module" do
    test "from_opts/2 creates alias" do
      alias_def = Alias.from_opts("old.path", to: "new.path")
      assert alias_def.from == "old.path"
      assert alias_def.to == "new.path"
      refute alias_def.deprecated
    end

    test "from_opts/2 with deprecated flag" do
      alias_def = Alias.from_opts("legacy", to: "v2.api", deprecated: true)
      assert alias_def.deprecated
    end

    test "validate/1 checks alias format" do
      assert :ok == Alias.validate(%Alias{from: "old", to: "new"})
      assert {:error, _} = Alias.validate(%Alias{from: "old", to: "old"})
    end

    test "valid_path_format?/1 allows camelCase for aliases" do
      assert Alias.valid_path_format?("getUser")
      assert Alias.valid_path_format?("users.getUser")
      assert Alias.valid_path_format?("snake_case")
    end
  end

  describe "SimpleRouter introspection" do
    test "__zrpc_paths__/0 returns all paths" do
      paths = SimpleRouter.__zrpc_paths__()

      assert "users.get" in paths
      assert "users.list" in paths
      assert "users.create" in paths
      assert "posts.get" in paths
      assert "posts.list" in paths
    end

    test "__zrpc_entry__/1 returns entry by path" do
      entry = SimpleRouter.__zrpc_entry__("users.get")

      assert entry.path == "users.get"
      assert entry.procedure_name == :get
      assert entry.procedure_type == :query
      assert entry.source_module == UserProcedures
    end

    test "__zrpc_entry__/1 returns nil for unknown path" do
      assert nil == SimpleRouter.__zrpc_entry__("unknown.path")
    end

    test "__zrpc_has_path__?/1 checks path existence" do
      assert SimpleRouter.__zrpc_has_path__?("users.get")
      refute SimpleRouter.__zrpc_has_path__?("unknown.path")
    end

    test "__zrpc_modules__/0 returns registered modules" do
      modules = SimpleRouter.__zrpc_modules__()

      assert UserProcedures in modules
      assert PostProcedures in modules
    end

    test "__zrpc_queries__/0 returns only queries" do
      queries = SimpleRouter.__zrpc_queries__()

      assert Enum.all?(queries, &(&1.procedure_type == :query))
      assert length(queries) == 4
    end

    test "__zrpc_mutations__/0 returns only mutations" do
      mutations = SimpleRouter.__zrpc_mutations__()

      assert Enum.all?(mutations, &(&1.procedure_type == :mutation))
      assert length(mutations) == 1
    end

    test "__zrpc_entries_by_prefix__/1 filters by prefix" do
      user_entries = SimpleRouter.__zrpc_entries_by_prefix__("users")

      assert length(user_entries) == 3
      assert Enum.all?(user_entries, &String.starts_with?(&1.path, "users"))
    end
  end

  describe "RouterWithMiddleware" do
    test "middleware is included in entry" do
      entry = RouterWithMiddleware.__zrpc_entry__("users.get")

      assert TestMiddleware.Logger in entry.middleware
      assert TestMiddleware.Auth in entry.middleware
    end
  end

  describe "RouterWithScopes" do
    test "scope prefix is included in path" do
      paths = RouterWithScopes.__zrpc_paths__()

      assert "admin.actions.stats" in paths
      assert "admin.actions.delete_user" in paths
      assert "admin.super.super_actions.stats" in paths
    end

    test "scope middleware is inherited" do
      entry = RouterWithScopes.__zrpc_entry__("admin.actions.stats")

      assert TestMiddleware.Logger in entry.middleware
      assert TestMiddleware.Auth in entry.middleware
      assert TestMiddleware.Admin in entry.middleware
    end

    test "deeply nested scopes work" do
      entry = RouterWithScopes.__zrpc_entry__("admin.super.super_actions.stats")

      assert entry.path == "admin.super.super_actions.stats"
      assert TestMiddleware.Logger in entry.middleware
      assert TestMiddleware.Auth in entry.middleware
      assert TestMiddleware.Admin in entry.middleware
    end

    test "root procedures don't have scope middleware" do
      entry = RouterWithScopes.__zrpc_entry__("users.get")

      assert TestMiddleware.Logger in entry.middleware
      refute TestMiddleware.Auth in entry.middleware
      refute TestMiddleware.Admin in entry.middleware
    end
  end

  describe "RouterWithAliases" do
    test "__zrpc_aliases__/0 returns all aliases" do
      aliases = RouterWithAliases.__zrpc_aliases__()

      assert Map.has_key?(aliases, "users.get_user")
      assert Map.has_key?(aliases, "getUser")
    end

    test "__zrpc_alias__/1 returns alias definition" do
      alias_def = RouterWithAliases.__zrpc_alias__("users.get_user")

      assert alias_def.from == "users.get_user"
      assert alias_def.to == "users.get"
      refute alias_def.deprecated
    end

    test "__zrpc_alias__/1 returns nil for non-alias" do
      assert nil == RouterWithAliases.__zrpc_alias__("users.get")
    end

    test "deprecated alias is marked" do
      alias_def = RouterWithAliases.__zrpc_alias__("getUser")

      assert alias_def.deprecated
    end

    test "__zrpc_resolve__/1 resolves aliases" do
      entry = RouterWithAliases.__zrpc_resolve__("users.get_user")

      assert entry.path == "users.get"
    end

    test "__zrpc_resolve__/1 returns direct entry" do
      entry = RouterWithAliases.__zrpc_resolve__("users.get")

      assert entry.path == "users.get"
    end
  end

  describe "RouterWithSkipMiddleware" do
    test "skipped middleware is not in entry" do
      entry = RouterWithSkipMiddleware.__zrpc_entry__("health.check")

      refute TestMiddleware.Auth in entry.middleware
    end

    test "non-skipped entries still have middleware" do
      entry = RouterWithSkipMiddleware.__zrpc_entry__("users.get")

      assert TestMiddleware.Auth in entry.middleware
    end
  end

  describe "Router.call/5" do
    test "executes procedure by path" do
      ctx = Context.new()

      {:ok, result} = Router.call(SimpleRouter, "users.get", %{id: "123"}, ctx)

      assert result.id == "123"
      assert result.name == "User 123"
    end

    test "returns error for unknown path" do
      ctx = Context.new()

      {:error, error} = Router.call(SimpleRouter, "unknown.path", %{}, ctx)

      assert error.code == :not_found
      assert error.path == "unknown.path"
    end

    test "includes suggestions for similar paths" do
      ctx = Context.new()

      {:error, error} = Router.call(SimpleRouter, "users.gett", %{}, ctx)

      assert "users.get" in error.suggestions
    end

    test "returns error for invalid path format" do
      ctx = Context.new()

      {:error, error} = Router.call(SimpleRouter, "Invalid..Path", %{}, ctx)

      assert error.code == :invalid_path
    end

    test "middleware is executed" do
      ctx = Context.new()

      {:ok, result} = Router.call(RouterWithMiddleware, "users.get", %{id: "1"}, ctx)

      assert result.authed == true
    end

    test "resolves via alias" do
      ctx = Context.new()

      {:ok, result} = Router.call(RouterWithAliases, "users.get_user", %{id: "123"}, ctx)

      assert result.id == "123"
    end
  end

  describe "Router.batch/4" do
    test "executes multiple procedures" do
      ctx = Context.new()

      results =
        Router.batch(
          SimpleRouter,
          [
            {"users.get", %{id: "1"}},
            {"users.get", %{id: "2"}},
            {"posts.get", %{id: "p1"}}
          ],
          ctx
        )

      assert length(results) == 3
      assert {:ok, %{id: "1"}} = Enum.at(results, 0)
      assert {:ok, %{id: "2"}} = Enum.at(results, 1)
      assert {:ok, %{id: "p1"}} = Enum.at(results, 2)
    end

    test "handles mixed success and failure" do
      ctx = Context.new()

      results =
        Router.batch(
          SimpleRouter,
          [
            {"users.get", %{id: "1"}},
            {"unknown.path", %{}}
          ],
          ctx
        )

      assert {:ok, _} = Enum.at(results, 0)
      assert {:error, %{code: :not_found}} = Enum.at(results, 1)
    end

    test "respects max_batch_size" do
      ctx = Context.new()
      calls = Enum.map(1..10, &{"users.get", %{id: "#{&1}"}})

      results = Router.batch(SimpleRouter, calls, ctx, max_batch_size: 5)

      assert [{:error, %{code: :batch_too_large}}] = results
    end

    test "empty batch returns empty list" do
      ctx = Context.new()

      results = Router.batch(SimpleRouter, [], ctx)

      assert results == []
    end
  end
end

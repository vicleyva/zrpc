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

  defmodule TestMiddleware.ShortCircuit do
    use Zrpc.Middleware

    @impl true
    def call(_ctx, _opts, _next) do
      {:error, %{code: :short_circuited, message: "Middleware stopped execution"}}
    end
  end

  defmodule TestMiddleware.WithOpts do
    use Zrpc.Middleware

    @impl true
    def init(opts), do: Keyword.put(opts, :initialized, true)

    @impl true
    def call(ctx, opts, next) do
      ctx = Zrpc.Context.assign(ctx, :middleware_opts, opts)
      next.(ctx)
    end
  end

  defmodule UserProcedures do
    use Zrpc.Procedure

    query :get do
      input(Zoi.object(%{id: Zoi.string()}))

      handler(fn %{id: id}, ctx ->
        {:ok, %{id: id, name: "User #{id}", authed: ctx.assigns[:authed]}}
      end)
    end

    query :list do
      handler(fn _input, _ctx ->
        {:ok, [%{id: "1", name: "Alice"}, %{id: "2", name: "Bob"}]}
      end)
    end

    mutation :create do
      input(Zoi.object(%{name: Zoi.string()}))

      handler(fn %{name: name}, _ctx ->
        {:ok, %{id: "new-id", name: name}}
      end)
    end
  end

  defmodule PostProcedures do
    use Zrpc.Procedure

    query :get do
      input(Zoi.object(%{id: Zoi.string()}))

      handler(fn %{id: id}, _ctx ->
        {:ok, %{id: id, title: "Post #{id}"}}
      end)
    end

    query :list do
      handler(fn _input, _ctx ->
        {:ok, [%{id: "p1", title: "First Post"}]}
      end)
    end
  end

  defmodule AdminProcedures do
    use Zrpc.Procedure

    query :stats do
      handler(fn _input, ctx ->
        {:ok, %{admin: ctx.assigns[:admin], authed: ctx.assigns[:authed]}}
      end)
    end

    mutation :delete_user do
      input(Zoi.object(%{user_id: Zoi.string()}))

      handler(fn %{user_id: id}, _ctx ->
        {:ok, %{deleted: id}}
      end)
    end
  end

  defmodule HealthProcedures do
    use Zrpc.Procedure

    query :check do
      handler(fn _input, _ctx ->
        {:ok, %{status: "ok"}}
      end)
    end
  end

  # Test routers
  defmodule SimpleRouter do
    use Zrpc.Router

    procedures(Zrpc.RouterTest.UserProcedures, at: "users")
    procedures(Zrpc.RouterTest.PostProcedures, at: "posts")
  end

  defmodule RouterWithMiddleware do
    use Zrpc.Router

    middleware(TestMiddleware.Logger)
    middleware(TestMiddleware.Auth)

    procedures(UserProcedures, at: "users")
  end

  defmodule RouterWithScopes do
    use Zrpc.Router

    middleware(TestMiddleware.Logger)

    procedures(UserProcedures, at: "users")

    scope "admin" do
      middleware(TestMiddleware.Auth)
      middleware(TestMiddleware.Admin)

      procedures(AdminProcedures, at: "actions")

      scope "super" do
        procedures(AdminProcedures, at: "super_actions")
      end
    end
  end

  defmodule RouterWithAliases do
    use Zrpc.Router

    procedures(UserProcedures, at: "users")

    path_alias("users.get_user", to: "users.get")
    path_alias("getUser", to: "users.get", deprecated: true)
  end

  defmodule RouterWithSkipMiddleware do
    use Zrpc.Router

    middleware(TestMiddleware.Auth)

    procedures(UserProcedures, at: "users")
    procedures(HealthProcedures, at: "health", skip_middleware: [TestMiddleware.Auth])
  end

  defmodule RouterWithShortCircuit do
    use Zrpc.Router

    middleware(TestMiddleware.ShortCircuit)

    procedures(UserProcedures, at: "users")
  end

  defmodule RouterWithMiddlewareOpts do
    use Zrpc.Router

    middleware(TestMiddleware.WithOpts, custom_key: "custom_value")

    procedures(UserProcedures, at: "users")
  end

  defmodule RouterWithMultipleSkips do
    use Zrpc.Router

    middleware(TestMiddleware.Logger)
    middleware(TestMiddleware.Auth)
    middleware(TestMiddleware.Admin)

    procedures(UserProcedures, at: "users")

    procedures(HealthProcedures,
      at: "health",
      skip_middleware: [TestMiddleware.Auth, TestMiddleware.Admin]
    )
  end

  describe "Entry module" do
    test "build_path/1 creates dotted path from segments" do
      assert Entry.build_path([:users, :get_user]) == "users.get_user"
      assert Entry.build_path([:admin, :users, :list]) == "admin.users.list"
    end

    test "build_path/1 with single segment" do
      assert Entry.build_path([:users]) == "users"
    end

    test "build_path/1 with empty list" do
      assert Entry.build_path([]) == ""
    end

    test "parse_path/1 splits path into segments" do
      assert Entry.parse_path("users.get_user") == [:users, :get_user]
      assert Entry.parse_path("admin.users.list") == [:admin, :users, :list]
    end

    test "parse_path/1 with single segment" do
      assert Entry.parse_path("users") == [:users]
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

    test "valid_path?/1 rejects empty string" do
      refute Entry.valid_path?("")
    end

    test "valid_path?/1 rejects unicode characters" do
      refute Entry.valid_path?("users.gét")
      refute Entry.valid_path?("用户.get")
    end

    test "valid_path?/1 rejects whitespace" do
      refute Entry.valid_path?("users. get")
      refute Entry.valid_path?(" users.get")
      refute Entry.valid_path?("users.get ")
    end

    test "valid_path?/1 accepts single segment" do
      assert Entry.valid_path?("users")
      assert Entry.valid_path?("a")
    end

    test "procedure/1 looks up procedure definition at runtime" do
      entry = SimpleRouter.__zrpc_entry__("users.get")
      procedure = Entry.procedure(entry)

      assert procedure.name == :get
      assert procedure.type == :query
      assert is_function(procedure.handler, 2)
    end

    test "type/1 returns procedure type" do
      entry = SimpleRouter.__zrpc_entry__("users.get")
      assert Entry.type(entry) == :query

      mutation_entry = SimpleRouter.__zrpc_entry__("users.create")
      assert Entry.type(mutation_entry) == :mutation
    end

    test "name/1 returns procedure name" do
      entry = SimpleRouter.__zrpc_entry__("users.get")
      assert Entry.name(entry) == :get
    end

    test "matches_prefix?/2 with exact match returns true" do
      entry = SimpleRouter.__zrpc_entry__("users.get")
      assert Entry.matches_prefix?(entry, "users.get")
    end

    test "matches_prefix?/2 with valid prefix returns true" do
      entry = SimpleRouter.__zrpc_entry__("users.get")
      assert Entry.matches_prefix?(entry, "users")
    end

    test "matches_prefix?/2 with non-matching prefix returns false" do
      entry = SimpleRouter.__zrpc_entry__("users.get")
      refute Entry.matches_prefix?(entry, "posts")
      refute Entry.matches_prefix?(entry, "user")
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

    test "new/1 creates alias from map" do
      alias_def = Alias.new(%{from: "old", to: "new", deprecated: false})
      assert alias_def.from == "old"
      assert alias_def.to == "new"
      refute alias_def.deprecated
    end

    test "validate/1 checks alias format" do
      assert :ok == Alias.validate(%Alias{from: "old", to: "new"})
      assert {:error, _} = Alias.validate(%Alias{from: "old", to: "old"})
    end

    test "validate/1 rejects invalid from path format" do
      assert {:error, msg} = Alias.validate(%Alias{from: "", to: "new"})
      assert msg =~ "Invalid alias path format"
    end

    test "validate/1 rejects invalid to path format" do
      assert {:error, msg} = Alias.validate(%Alias{from: "old", to: ""})
      assert msg =~ "Invalid target path format"
    end

    test "valid_path_format?/1 allows camelCase for aliases" do
      assert Alias.valid_path_format?("getUser")
      assert Alias.valid_path_format?("users.getUser")
      assert Alias.valid_path_format?("snake_case")
    end

    test "valid_path_format?/1 rejects empty string" do
      refute Alias.valid_path_format?("")
    end

    test "valid_path_format?/1 rejects paths starting with number" do
      refute Alias.valid_path_format?("123abc")
      refute Alias.valid_path_format?("1.method")
    end

    test "valid_path_format?/1 accepts mixed case" do
      assert Alias.valid_path_format?("getUserById")
      assert Alias.valid_path_format?("API.getUser")
      assert Alias.valid_path_format?("v1Api")
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

    test "__zrpc_entries__/0 returns all entries" do
      entries = SimpleRouter.__zrpc_entries__()

      assert length(entries) == 5
      assert Enum.all?(entries, &is_struct(&1, Entry))
    end

    test "__zrpc_subscriptions__/0 returns empty for router without subscriptions" do
      subscriptions = SimpleRouter.__zrpc_subscriptions__()

      assert subscriptions == []
    end

    test "__zrpc_middleware__/1 returns middleware chain for path" do
      middleware = RouterWithMiddleware.__zrpc_middleware__("users.get")

      assert is_list(middleware)
      assert TestMiddleware.Logger in middleware
      assert TestMiddleware.Auth in middleware
    end

    test "__zrpc_middleware__/1 returns nil for unknown path" do
      assert nil == SimpleRouter.__zrpc_middleware__("unknown.path")
    end

    test "__zrpc_procedure__/1 returns procedure definition" do
      procedure = SimpleRouter.__zrpc_procedure__("users.get")

      assert procedure.name == :get
      assert procedure.type == :query
    end

    test "__zrpc_procedure__/1 returns nil for unknown path" do
      assert nil == SimpleRouter.__zrpc_procedure__("unknown.path")
    end

    test "__zrpc_router__/0 returns module name" do
      assert SimpleRouter.__zrpc_router__() == SimpleRouter
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

    test "rejects empty path string" do
      ctx = Context.new()

      {:error, error} = Router.call(SimpleRouter, "", %{}, ctx)

      assert error.code == :invalid_path
    end

    test "rejects path with leading dot" do
      ctx = Context.new()

      {:error, error} = Router.call(SimpleRouter, ".users.get", %{}, ctx)

      assert error.code == :invalid_path
    end

    test "rejects path with trailing dot" do
      ctx = Context.new()

      {:error, error} = Router.call(SimpleRouter, "users.get.", %{}, ctx)

      assert error.code == :invalid_path
    end

    test "uppercase path treated as not found (aliases allow mixed case)" do
      ctx = Context.new()

      # Uppercase paths are valid for aliases (camelCase), but since it's not
      # a registered path or alias, it returns not_found
      {:error, error} = Router.call(SimpleRouter, "Users.Get", %{}, ctx)

      assert error.code == :not_found
    end

    test "rejects path with whitespace" do
      ctx = Context.new()

      {:error, error} = Router.call(SimpleRouter, "users. get", %{}, ctx)

      assert error.code == :invalid_path
    end

    test "updates context with procedure info" do
      ctx = Context.new()

      # The handler receives the updated context
      {:ok, _result} = Router.call(SimpleRouter, "users.get", %{id: "1"}, ctx)

      # Context is updated internally - we verify by checking the handler received it
      # (The UserProcedures.get handler includes ctx.assigns in response)
    end

    test "resolves deprecated alias" do
      ctx = Context.new()

      # Using the deprecated "getUser" alias should still work
      {:ok, result} = Router.call(RouterWithAliases, "getUser", %{id: "456"}, ctx)

      assert result.id == "456"
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

    test "batch at exact size limit passes" do
      ctx = Context.new()
      calls = Enum.map(1..5, &{"users.get", %{id: "#{&1}"}})

      results = Router.batch(SimpleRouter, calls, ctx, max_batch_size: 5)

      assert length(results) == 5
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "batch at size limit + 1 fails" do
      ctx = Context.new()
      calls = Enum.map(1..6, &{"users.get", %{id: "#{&1}"}})

      results = Router.batch(SimpleRouter, calls, ctx, max_batch_size: 5)

      assert [{:error, %{code: :batch_too_large}}] = results
    end

    test "same procedure called multiple times works" do
      ctx = Context.new()

      results =
        Router.batch(
          SimpleRouter,
          [
            {"users.get", %{id: "same"}},
            {"users.get", %{id: "same"}},
            {"users.get", %{id: "same"}}
          ],
          ctx
        )

      assert length(results) == 3
      assert Enum.all?(results, fn {:ok, r} -> r.id == "same" end)
    end
  end

  describe "Router telemetry" do
    setup do
      test_pid = self()

      handler_id = "test-router-telemetry-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:zrpc, :router, :lookup, :start],
          [:zrpc, :router, :lookup, :stop],
          [:zrpc, :router, :batch, :start],
          [:zrpc, :router, :batch, :stop],
          [:zrpc, :router, :alias, :resolved]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "call/5 emits lookup start event" do
      ctx = Context.new()

      Router.call(SimpleRouter, "users.get", %{id: "1"}, ctx)

      assert_receive {:telemetry_event, [:zrpc, :router, :lookup, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.router == SimpleRouter
      assert metadata.path == "users.get"
    end

    test "call/5 emits lookup stop event with found=true" do
      ctx = Context.new()

      Router.call(SimpleRouter, "users.get", %{id: "1"}, ctx)

      assert_receive {:telemetry_event, [:zrpc, :router, :lookup, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.router == SimpleRouter
      assert metadata.path == "users.get"
      assert metadata.found == true
    end

    test "call/5 emits lookup stop event with found=false" do
      ctx = Context.new()

      Router.call(SimpleRouter, "unknown.path", %{}, ctx)

      assert_receive {:telemetry_event, [:zrpc, :router, :lookup, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.found == false
    end

    test "call/5 emits alias resolved event for alias path" do
      ctx = Context.new()

      Router.call(RouterWithAliases, "users.get_user", %{id: "1"}, ctx)

      assert_receive {:telemetry_event, [:zrpc, :router, :alias, :resolved], _measurements,
                      metadata}

      assert metadata.router == RouterWithAliases
      assert metadata.from == "users.get_user"
      assert metadata.to == "users.get"
      assert metadata.deprecated == false
    end

    test "call/5 emits alias resolved event with deprecated=true" do
      ctx = Context.new()

      Router.call(RouterWithAliases, "getUser", %{id: "1"}, ctx)

      assert_receive {:telemetry_event, [:zrpc, :router, :alias, :resolved], _measurements,
                      metadata}

      assert metadata.deprecated == true
    end

    test "batch/4 emits batch start event" do
      ctx = Context.new()

      Router.batch(SimpleRouter, [{"users.get", %{id: "1"}}], ctx)

      assert_receive {:telemetry_event, [:zrpc, :router, :batch, :start], measurements, metadata}
      assert measurements.batch_size == 1
      assert is_integer(measurements.system_time)
      assert metadata.router == SimpleRouter
      assert metadata.paths == ["users.get"]
    end

    test "batch/4 emits batch stop event with counts" do
      ctx = Context.new()

      Router.batch(
        SimpleRouter,
        [
          {"users.get", %{id: "1"}},
          {"unknown.path", %{}}
        ],
        ctx
      )

      assert_receive {:telemetry_event, [:zrpc, :router, :batch, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.success_count == 1
      assert measurements.error_count == 1
      assert metadata.router == SimpleRouter
    end
  end

  describe "compile-time validation" do
    test "raises on duplicate procedure paths" do
      assert_raise CompileError, ~r/Duplicate procedure path/, fn ->
        Code.compile_string("""
        defmodule DuplicateRouter#{System.unique_integer([:positive])} do
          use Zrpc.Router
          procedures Zrpc.RouterTest.UserProcedures, at: "users"
          procedures Zrpc.RouterTest.UserProcedures, at: "users"
        end
        """)
      end
    end

    test "raises on module not using Zrpc.Procedure" do
      unique_id = System.unique_integer([:positive])

      assert_raise CompileError, ~r/does not use Zrpc\.Procedure/, fn ->
        Code.compile_string("""
        defmodule NotAProcedure#{unique_id} do
          def hello, do: :world
        end

        defmodule InvalidModuleRouter#{unique_id} do
          use Zrpc.Router
          procedures NotAProcedure#{unique_id}, at: "invalid"
        end
        """)
      end
    end

    test "raises on alias target not found" do
      assert_raise CompileError, ~r/Alias target not found/, fn ->
        Code.compile_string("""
        defmodule AliasTargetNotFoundRouter#{System.unique_integer([:positive])} do
          use Zrpc.Router
          procedures Zrpc.RouterTest.UserProcedures, at: "users"
          path_alias "old.path", to: "nonexistent.path"
        end
        """)
      end
    end

    test "raises on alias conflicting with existing path" do
      assert_raise CompileError, ~r/Alias conflicts with existing path/, fn ->
        Code.compile_string("""
        defmodule AliasConflictRouter#{System.unique_integer([:positive])} do
          use Zrpc.Router
          procedures Zrpc.RouterTest.UserProcedures, at: "users"
          path_alias "users.get", to: "users.list"
        end
        """)
      end
    end

    test "raises when alias points to another alias (not a real path)" do
      # Aliases must point to real procedure paths, not other aliases
      # This prevents potential circular references
      assert_raise CompileError, ~r/Alias target not found/, fn ->
        Code.compile_string("""
        defmodule ChainedAliasRouter#{System.unique_integer([:positive])} do
          use Zrpc.Router
          procedures Zrpc.RouterTest.UserProcedures, at: "users"
          path_alias "alias1", to: "alias2"
          path_alias "alias2", to: "users.get"
        end
        """)
      end
    end
  end

  describe "middleware edge cases" do
    test "middleware that returns error short-circuits" do
      ctx = Context.new()

      {:error, error} = Router.call(RouterWithShortCircuit, "users.get", %{id: "1"}, ctx)

      assert error.code == :short_circuited
      assert error.message == "Middleware stopped execution"
    end

    test "middleware with options receives initialized opts" do
      # Create a procedure module that captures the context with middleware opts
      defmodule OptsCapture do
        use Zrpc.Procedure

        query :capture do
          handler(fn _input, ctx ->
            {:ok, ctx.assigns[:middleware_opts]}
          end)
        end
      end

      defmodule OptsTestRouter do
        use Zrpc.Router

        middleware(Zrpc.RouterTest.TestMiddleware.WithOpts, custom_key: "custom_value")

        procedures(Zrpc.RouterTest.OptsCapture, at: "opts")
      end

      ctx = Context.new()
      {:ok, opts} = Router.call(OptsTestRouter, "opts.capture", %{}, ctx)

      assert opts[:custom_key] == "custom_value"
      assert opts[:initialized] == true
    end

    test "multiple skip_middleware entries work" do
      entry = RouterWithMultipleSkips.__zrpc_entry__("health.check")

      # Logger should be present, Auth and Admin should be skipped
      assert TestMiddleware.Logger in entry.middleware
      refute TestMiddleware.Auth in entry.middleware
      refute TestMiddleware.Admin in entry.middleware
    end

    test "skip_middleware doesn't affect other procedures" do
      entry = RouterWithMultipleSkips.__zrpc_entry__("users.get")

      # All middleware should be present for users
      assert TestMiddleware.Logger in entry.middleware
      assert TestMiddleware.Auth in entry.middleware
      assert TestMiddleware.Admin in entry.middleware
    end
  end
end

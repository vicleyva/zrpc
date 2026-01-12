defmodule Zrpc.ProcedureTest do
  use ExUnit.Case, async: true

  alias Zrpc.Context

  # Test module with various procedure definitions
  defmodule TestProcedures do
    use Zrpc.Procedure

    query :get_user do
      meta do
        description("Get a user by ID")
        tags(["users"])
      end

      input(Zoi.object(%{id: Zoi.string()}))
      output(Zoi.object(%{id: Zoi.string(), name: Zoi.string()}))

      handler(fn %{id: id}, _ctx ->
        {:ok, %{id: id, name: "Test User"}}
      end)
    end

    mutation :create_user do
      meta(description: "Create a new user", tags: ["users"])

      input(Zoi.object(%{name: Zoi.string(), email: Zoi.string()}))

      handler(fn input, _ctx ->
        {:ok, Map.put(input, :id, "generated-id")}
      end)
    end

    query :with_route do
      route(method: :get, path: "/items/{id}")
      handler(fn input, _ctx -> {:ok, input} end)
    end

    subscription :user_updates do
      input(Zoi.object(%{user_id: Zoi.string()}))
      handler(fn _input, _ctx -> {:ok, :stream} end)
    end

    # Test implicit handler
    query :implicit_handler do
      input(Zoi.object(%{value: Zoi.string()}))
    end

    def implicit_handler(%{value: value}, _ctx) do
      {:ok, %{result: "handled: #{value}"}}
    end

    # Test procedure with middleware
    query :with_middleware do
      middleware(Zrpc.ProcedureTest.TestMiddleware)
      middleware(Zrpc.ProcedureTest.TestMiddleware, prefix: "custom")

      handler(fn _input, ctx ->
        {:ok, %{middleware_ran: Context.get_assign(ctx, :test_ran, false)}}
      end)
    end
  end

  defmodule TestMiddleware do
    use Zrpc.Middleware

    @impl true
    def init(opts) do
      %{prefix: Keyword.get(opts, :prefix, "default")}
    end

    @impl true
    def call(ctx, _opts, next) do
      ctx = Context.assign(ctx, :test_ran, true)
      next.(ctx)
    end
  end

  describe "__zrpc_procedures__/0" do
    test "returns all procedures" do
      procedures = TestProcedures.__zrpc_procedures__()
      assert length(procedures) == 6
    end

    test "procedures are in definition order" do
      procedures = TestProcedures.__zrpc_procedures__()
      names = Enum.map(procedures, & &1.name)

      assert names == [
               :get_user,
               :create_user,
               :with_route,
               :user_updates,
               :implicit_handler,
               :with_middleware
             ]
    end
  end

  describe "__zrpc_procedure__/1" do
    test "returns procedure by name" do
      proc = TestProcedures.__zrpc_procedure__(:get_user)
      assert proc.name == :get_user
      assert proc.type == :query
      assert proc.meta.description == "Get a user by ID"
      assert proc.meta.tags == ["users"]
    end

    test "returns nil for unknown procedure" do
      assert TestProcedures.__zrpc_procedure__(:unknown) == nil
    end
  end

  describe "__zrpc_queries__/0" do
    test "returns only query procedures" do
      queries = TestProcedures.__zrpc_queries__()
      assert length(queries) == 4
      assert Enum.all?(queries, &(&1.type == :query))
    end
  end

  describe "__zrpc_mutations__/0" do
    test "returns only mutation procedures" do
      mutations = TestProcedures.__zrpc_mutations__()
      assert length(mutations) == 1
      assert hd(mutations).name == :create_user
    end
  end

  describe "__zrpc_subscriptions__/0" do
    test "returns only subscription procedures" do
      subs = TestProcedures.__zrpc_subscriptions__()
      assert length(subs) == 1
      assert hd(subs).name == :user_updates
    end
  end

  describe "__zrpc_procedure_names__/0" do
    test "returns all procedure names" do
      names = TestProcedures.__zrpc_procedure_names__()
      assert :get_user in names
      assert :create_user in names
      assert :user_updates in names
    end
  end

  describe "__zrpc_has_procedure__?/1" do
    test "returns true for existing procedure" do
      assert TestProcedures.__zrpc_has_procedure__?(:get_user)
    end

    test "returns false for non-existing procedure" do
      refute TestProcedures.__zrpc_has_procedure__?(:non_existing)
    end
  end

  describe "__zrpc_module__/0" do
    test "returns the module name" do
      assert TestProcedures.__zrpc_module__() == TestProcedures
    end
  end

  describe "procedure handler execution" do
    test "handler can be called directly" do
      proc = TestProcedures.__zrpc_procedure__(:get_user)
      ctx = Context.new()

      assert {:ok, result} = proc.handler.(%{id: "123"}, ctx)
      assert result.id == "123"
      assert result.name == "Test User"
    end
  end

  describe "route definition" do
    test "captures route config" do
      proc = TestProcedures.__zrpc_procedure__(:with_route)
      assert proc.route.method == :get
      assert proc.route.path == "/items/{id}"
    end

    test "route is nil when not defined" do
      proc = TestProcedures.__zrpc_procedure__(:get_user)
      assert proc.route == nil
    end
  end

  describe "middleware definition" do
    test "captures middleware specifications" do
      proc = TestProcedures.__zrpc_procedure__(:with_middleware)
      assert length(proc.middleware) == 2

      [first, second] = proc.middleware
      assert first == TestMiddleware
      assert second == {TestMiddleware, [prefix: "custom"]}
    end

    test "middleware is empty list when not defined" do
      proc = TestProcedures.__zrpc_procedure__(:get_user)
      assert proc.middleware == []
    end
  end

  describe "meta parsing" do
    test "parses block syntax meta" do
      proc = TestProcedures.__zrpc_procedure__(:get_user)
      assert proc.meta.description == "Get a user by ID"
      assert proc.meta.tags == ["users"]
    end

    test "parses keyword syntax meta" do
      proc = TestProcedures.__zrpc_procedure__(:create_user)
      assert proc.meta.description == "Create a new user"
      assert proc.meta.tags == ["users"]
    end
  end

  describe "source location" do
    test "captures source file and line" do
      proc = TestProcedures.__zrpc_procedure__(:get_user)
      assert proc.__source__.file =~ "procedure_test.exs"
      assert proc.__source__.line > 0
      assert proc.__source__.module == TestProcedures
    end
  end

  describe "implicit handler" do
    test "procedure without handler directive uses module function" do
      proc = TestProcedures.__zrpc_procedure__(:implicit_handler)
      assert proc.handler == nil
    end
  end
end

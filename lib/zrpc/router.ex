defmodule Zrpc.Router do
  @moduledoc """
  DSL for organizing RPC procedures into a hierarchical namespace tree.

  ## Usage

      defmodule MyApp.Router do
        use Zrpc.Router

        # Router-level middleware (applies to all procedures)
        middleware MyApp.Middleware.RequestId
        middleware MyApp.Middleware.Logger

        # Register procedure modules at namespace paths
        procedures MyApp.Procedures.Users, at: "users"
        procedures MyApp.Procedures.Posts, at: "posts"

        # Nested scopes with scoped middleware
        scope "admin" do
          middleware MyApp.Middleware.RequireAdmin

          procedures MyApp.Procedures.AdminUsers, at: "users"
          procedures MyApp.Procedures.AdminSettings, at: "settings"
        end
      end

  This creates procedure paths like:
  - `users.get_user`, `users.create_user`
  - `posts.get_post`, `posts.list_posts`
  - `admin.users.list_all`, `admin.settings.update`

  ## Path Aliases

  Define alternative names for procedures (useful for backwards compatibility):

      alias "users.get_user", to: "users.get"
      alias "getUser", to: "users.get", deprecated: true

  ## Executing Procedures

      # Single call
      Zrpc.Router.call(MyApp.Router, "users.get", %{id: "123"}, ctx)

      # Batch call
      Zrpc.Router.batch(MyApp.Router, [
        {"users.get", %{id: "123"}},
        {"posts.list", %{user_id: "123"}}
      ], ctx)
  """

  alias Zrpc.Context
  alias Zrpc.Procedure.Executor
  alias Zrpc.Router.{Alias, Entry}

  @doc """
  Executes a procedure by path.

  ## Options

  - All options supported by `Zrpc.Procedure.Executor.execute/4`

  ## Examples

      Zrpc.Router.call(MyApp.Router, "users.get", %{id: "123"}, ctx)
      # => {:ok, %{id: "123", name: "Alice"}}

      Zrpc.Router.call(MyApp.Router, "unknown.path", %{}, ctx)
      # => {:error, %{code: :not_found, message: "Procedure not found: unknown.path"}}
  """
  @spec call(module(), String.t(), map(), Context.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call(router_module, path, input, ctx, opts \\ []) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:zrpc, :router, :lookup, :start],
      %{system_time: System.system_time()},
      %{router: router_module, path: path}
    )

    result =
      with :ok <- validate_path_format(path),
           {:ok, entry, resolved_via} <- resolve_path(router_module, path) do
        # Emit alias telemetry if resolved via alias
        maybe_emit_alias_telemetry(router_module, path, resolved_via)

        # Update context with procedure info
        ctx = Context.with_procedure(ctx, entry.path, entry.procedure_type)

        # Look up procedure definition at runtime (contains handler function)
        procedure = Entry.procedure(entry)

        # Execute with pre-computed middleware chain
        Executor.execute(
          procedure,
          input,
          ctx,
          Keyword.put(opts, :middleware, entry.middleware)
        )
      end

    duration = System.monotonic_time() - start_time
    found = match?({:ok, _}, result)

    :telemetry.execute(
      [:zrpc, :router, :lookup, :stop],
      %{duration: duration},
      %{router: router_module, path: path, found: found}
    )

    result
  end

  @doc """
  Executes multiple procedures in parallel.

  ## Options

  - `:max_concurrency` - Maximum parallel executions (default: 10)
  - `:timeout` - Per-procedure timeout in ms (default: 30_000)
  - `:max_batch_size` - Maximum calls per batch (default: 50)

  ## Examples

      Zrpc.Router.batch(MyApp.Router, [
        {"users.get", %{id: "123"}},
        {"posts.list", %{user_id: "123"}}
      ], ctx)
      # => [{:ok, %{...}}, {:ok, [...]}]
  """
  @spec batch(module(), [{String.t(), map()}], Context.t(), keyword()) ::
          [{:ok, term()} | {:error, term()}]
  def batch(router_module, calls, ctx, opts \\ []) do
    max_batch_size = Keyword.get(opts, :max_batch_size, 50)
    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    timeout = Keyword.get(opts, :timeout, 30_000)

    start_time = System.monotonic_time()
    paths = Enum.map(calls, &elem(&1, 0))

    :telemetry.execute(
      [:zrpc, :router, :batch, :start],
      %{system_time: System.system_time(), batch_size: length(calls)},
      %{router: router_module, paths: paths}
    )

    result =
      with :ok <- validate_batch_size(calls, max_batch_size) do
        results =
          calls
          |> Task.async_stream(
            fn {path, input} -> call(router_module, path, input, ctx, opts) end,
            max_concurrency: max_concurrency,
            timeout: timeout,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, :timeout} -> {:error, %{code: :timeout, message: "Procedure timed out"}}
          end)

        {:ok, results}
      end

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, results} ->
        success_count = Enum.count(results, &match?({:ok, _}, &1))
        error_count = length(results) - success_count

        :telemetry.execute(
          [:zrpc, :router, :batch, :stop],
          %{duration: duration, success_count: success_count, error_count: error_count},
          %{router: router_module}
        )

        results

      {:error, _} = error ->
        :telemetry.execute(
          [:zrpc, :router, :batch, :stop],
          %{duration: duration, success_count: 0, error_count: length(calls)},
          %{router: router_module}
        )

        [error]
    end
  end

  # Private helpers

  defp validate_path_format(path) do
    if Entry.valid_path?(path) or Alias.valid_path_format?(path) do
      :ok
    else
      {:error, %{code: :invalid_path, message: "Invalid path format: #{path}"}}
    end
  end

  defp validate_batch_size(calls, max_batch_size) do
    if length(calls) <= max_batch_size do
      :ok
    else
      {:error,
       %{
         code: :batch_too_large,
         message: "Batch size #{length(calls)} exceeds maximum of #{max_batch_size}"
       }}
    end
  end

  defp resolve_path(router_module, path) do
    case router_module.__zrpc_entry__(path) do
      nil -> resolve_via_alias(router_module, path)
      entry -> {:ok, entry, :direct}
    end
  end

  defp resolve_via_alias(router_module, path) do
    case router_module.__zrpc_alias__(path) do
      nil -> {:error, not_found_error(router_module, path)}
      %Alias{} = alias_def -> resolve_alias_target(router_module, path, alias_def)
    end
  end

  defp resolve_alias_target(router_module, path, %Alias{to: canonical, deprecated: deprecated}) do
    case router_module.__zrpc_entry__(canonical) do
      nil ->
        {:error, %{code: :not_found, message: "Alias target not found: #{canonical}", path: path}}

      entry ->
        {:ok, entry, {:alias, path, canonical, deprecated}}
    end
  end

  defp not_found_error(router_module, path) do
    %{
      code: :not_found,
      message: "Procedure not found: #{path}",
      path: path,
      suggestions: find_similar_paths(router_module, path)
    }
  end

  defp find_similar_paths(router_module, path) do
    router_module.__zrpc_paths__()
    |> Enum.filter(&(String.jaro_distance(&1, path) > 0.7))
    |> Enum.sort_by(&String.jaro_distance(&1, path), :desc)
    |> Enum.take(3)
  end

  defp maybe_emit_alias_telemetry(_router, _path, :direct), do: :ok

  defp maybe_emit_alias_telemetry(router, from, {:alias, _from, to, deprecated}) do
    :telemetry.execute(
      [:zrpc, :router, :alias, :resolved],
      %{},
      %{router: router, from: from, to: to, deprecated: deprecated}
    )
  end

  # DSL Macros

  defmacro __using__(_opts) do
    quote do
      require Zrpc.Router

      import Zrpc.Router,
        only: [
          middleware: 1,
          middleware: 2,
          procedures: 2,
          scope: 2,
          path_alias: 2
        ]

      # Module attributes for accumulating router configuration
      Module.register_attribute(__MODULE__, :zrpc_router_middleware, accumulate: true)
      Module.register_attribute(__MODULE__, :zrpc_router_registrations, accumulate: true)
      Module.register_attribute(__MODULE__, :zrpc_router_aliases, accumulate: true)

      # Scope tracking (not accumulated, managed via stack)
      Module.put_attribute(__MODULE__, :zrpc_scope_stack, [])
      Module.put_attribute(__MODULE__, :zrpc_scope_middleware, [])

      @before_compile Zrpc.Router.Compiler
    end
  end

  @doc """
  Adds middleware to the router or current scope.

  Middleware added at the router level applies to all procedures.
  Middleware added inside a scope applies only to procedures in that scope.

  ## Examples

      # Router-level middleware
      middleware MyApp.Middleware.Logger

      # With options
      middleware MyApp.Middleware.RateLimit, limit: 100

      # Inside a scope
      scope "admin" do
        middleware MyApp.Middleware.RequireAdmin
        procedures MyApp.Procedures.Admin, at: "actions"
      end
  """
  defmacro middleware(module) do
    quote do
      scope_stack = Module.get_attribute(__MODULE__, :zrpc_scope_stack)

      if scope_stack == [] do
        # Router-level middleware
        Module.put_attribute(__MODULE__, :zrpc_router_middleware, unquote(module))
      else
        # Scope-level middleware
        current_mw = Module.get_attribute(__MODULE__, :zrpc_scope_middleware)
        Module.put_attribute(__MODULE__, :zrpc_scope_middleware, [unquote(module) | current_mw])
      end
    end
  end

  defmacro middleware(module, opts) do
    quote do
      scope_stack = Module.get_attribute(__MODULE__, :zrpc_scope_stack)

      if scope_stack == [] do
        # Router-level middleware
        Module.put_attribute(
          __MODULE__,
          :zrpc_router_middleware,
          {unquote(module), unquote(opts)}
        )
      else
        # Scope-level middleware
        current_mw = Module.get_attribute(__MODULE__, :zrpc_scope_middleware)

        Module.put_attribute(
          __MODULE__,
          :zrpc_scope_middleware,
          [{unquote(module), unquote(opts)} | current_mw]
        )
      end
    end
  end

  @doc """
  Registers a procedure module at a namespace path.

  ## Options

  - `:at` (required) - The namespace path for this module's procedures
  - `:skip_middleware` - List of middleware modules to skip for this registration

  ## Examples

      procedures MyApp.Procedures.Users, at: "users"
      # Creates paths like: users.get_user, users.create_user

      procedures MyApp.Procedures.Health, at: "health", skip_middleware: [RequireAuth]
  """
  defmacro procedures(module, opts) do
    quote do
      namespace = Keyword.fetch!(unquote(opts), :at)
      skip_middleware = Keyword.get(unquote(opts), :skip_middleware, [])

      # Get current scope context
      scope_stack = Module.get_attribute(__MODULE__, :zrpc_scope_stack)
      scope_middleware = Module.get_attribute(__MODULE__, :zrpc_scope_middleware)

      # Build full prefix from scope stack
      scope_prefix =
        scope_stack
        |> Enum.reverse()
        |> Enum.map(&elem(&1, 0))

      # Collect scope middleware (in correct order)
      inherited_scope_mw =
        scope_stack
        |> Enum.reverse()
        |> Enum.flat_map(&elem(&1, 1))

      # Current scope's middleware + inherited
      all_scope_mw = Enum.reverse(scope_middleware) ++ inherited_scope_mw

      # Register for compile-time processing
      Module.put_attribute(__MODULE__, :zrpc_router_registrations, %{
        module: unquote(module),
        namespace: namespace,
        scope_prefix: scope_prefix,
        scope_middleware: all_scope_mw,
        skip_middleware: skip_middleware,
        file: __ENV__.file,
        line: __ENV__.line
      })
    end
  end

  @doc """
  Creates a nested scope with a path prefix and optional middleware.

  Scopes can be nested to any depth. Middleware in parent scopes
  applies to all procedures in child scopes.

  ## Examples

      scope "admin" do
        middleware MyApp.Middleware.RequireAdmin

        procedures MyApp.Procedures.AdminUsers, at: "users"
        # Creates: admin.users.get, admin.users.list, etc.

        scope "super" do
          middleware MyApp.Middleware.RequireSuperAdmin

          procedures MyApp.Procedures.SuperAdmin, at: "actions"
          # Creates: admin.super.actions.delete_all, etc.
        end
      end
  """
  defmacro scope(prefix, do: block) when is_binary(prefix) do
    quote do
      # Get current state
      current_stack = Module.get_attribute(__MODULE__, :zrpc_scope_stack)
      current_middleware = Module.get_attribute(__MODULE__, :zrpc_scope_middleware)

      # Push new scope onto stack (with current middleware)
      Module.put_attribute(
        __MODULE__,
        :zrpc_scope_stack,
        [{unquote(prefix), Enum.reverse(current_middleware)} | current_stack]
      )

      # Reset scope middleware for the new scope
      Module.put_attribute(__MODULE__, :zrpc_scope_middleware, [])

      # Execute the block (will add middleware, procedures, nested scopes)
      unquote(block)

      # Pop scope from stack
      [_ | rest] = Module.get_attribute(__MODULE__, :zrpc_scope_stack)
      Module.put_attribute(__MODULE__, :zrpc_scope_stack, rest)

      # Restore parent scope's middleware
      Module.put_attribute(__MODULE__, :zrpc_scope_middleware, current_middleware)
    end
  end

  @doc """
  Defines a path alias for a procedure.

  Note: Named `path_alias` because `alias` is a reserved keyword in Elixir.

  ## Options

  - `:to` (required) - The canonical path this alias points to
  - `:deprecated` - Mark as deprecated (emits telemetry when used)

  ## Examples

      # Backwards compatibility
      path_alias "users.get_user", to: "users.get"

      # Deprecated alias (logs warning when used)
      path_alias "getUser", to: "users.get", deprecated: true
  """
  defmacro path_alias(from, opts) when is_binary(from) and is_list(opts) do
    quote do
      Module.put_attribute(
        __MODULE__,
        :zrpc_router_aliases,
        Zrpc.Router.Alias.from_opts(unquote(from), unquote(opts))
      )
    end
  end
end

# Phase 1: Core DSL Implementation

## Overview

This phase implements the foundational DSL for defining RPC procedures. The goal is to create an ergonomic, compile-time validated API that feels natural to Elixir developers.

## Files to Create

```
lib/zrpc/
  procedure.ex                    # Main DSL module with macros
  procedure/
    definition.ex                 # Procedure struct
    compiler.ex                   # @before_compile hook
    meta_parser.ex                # Parse meta blocks at compile time
    executor.ex                   # Execute procedures with validation
  context.ex                      # Request context struct
```

---

## 1. Zrpc.Procedure.Definition

The struct that holds all procedure data.

```elixir
# lib/zrpc/procedure/definition.ex
defmodule Zrpc.Procedure.Definition do
  @moduledoc """
  Represents a single RPC procedure (query, mutation, or subscription).

  This struct is created at compile time and stored in module attributes.
  It contains all the information needed to:
  - Validate incoming requests (input schema)
  - Validate outgoing responses (output schema)
  - Execute the handler function
  - Generate documentation and TypeScript types
  """

  @type procedure_type :: :query | :mutation | :subscription

  @type meta :: %{
    optional(:description) => String.t(),
    optional(:tags) => [String.t()],
    optional(:examples) => [map()],
    optional(:deprecated) => boolean() | String.t()
  }

  @type route :: %{
    method: :get | :post | :put | :patch | :delete,
    path: String.t()
  }

  @type middleware_spec :: module() | {module(), keyword()}

  @type t :: %__MODULE__{
    name: atom(),
    type: procedure_type(),
    input: term() | nil,           # Zoi schema
    output: term() | nil,          # Zoi schema
    handler: (map(), Zrpc.Context.t() -> {:ok, term()} | {:error, term()}),
    meta: meta(),
    route: route() | nil,
    middleware: [middleware_spec()],  # Inline middleware
    __source__: %{file: String.t(), line: non_neg_integer(), module: module()}
  }

  @enforce_keys [:name, :type]  # handler can be nil for implicit handlers
  defstruct [
    :name,
    :type,
    :input,
    :output,
    :handler,
    :route,
    meta: %{},
    middleware: [],
    __source__: %{file: "unknown", line: 0, module: nil}
  ]

  @doc """
  Creates a new Definition from a map of attributes.
  Raises if required fields are missing.
  """
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Validates a procedure definition at compile time.
  Returns :ok or raises CompileError.
  """
  def validate!(%__MODULE__{} = proc, env) do
    validate_name!(proc, env)
    validate_type!(proc, env)
    validate_handler!(proc, env)
    validate_input!(proc, env)
    validate_output!(proc, env)
    validate_route!(proc, env)
    :ok
  end

  defp validate_name!(%{name: name}, env) when is_atom(name), do: :ok
  defp validate_name!(%{name: name, __source__: source}, env) do
    raise CompileError,
      file: source.file,
      line: source.line,
      description: "Procedure name must be an atom, got: #{inspect(name)}"
  end

  defp validate_type!(%{type: type}, _env) when type in [:query, :mutation, :subscription], do: :ok
  defp validate_type!(%{type: type, __source__: source}, _env) do
    raise CompileError,
      file: source.file,
      line: source.line,
      description: "Procedure type must be :query, :mutation, or :subscription, got: #{inspect(type)}"
  end

  defp validate_handler!(%{handler: handler}, _env) when is_function(handler, 2), do: :ok
  defp validate_handler!(%{handler: nil, name: name}, env) do
    # Implicit handler: check if module function exists
    # This validation runs at compile time via @before_compile
    # The function might be defined below the procedure, so we check at module compilation end
    unless Module.defines?(env.module, {name, 2}) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: """
        Procedure :#{name} has no handler defined.

        Either add an inline handler:

            query :#{name} do
              handler fn input, ctx -> {:ok, result} end
            end

        Or define a function with the same name:

            query :#{name} do
              input ...
            end

            def #{name}(input, ctx) do
              {:ok, result}
            end
        """
    end
    :ok
  end
  defp validate_handler!(%{handler: handler, __source__: source}, _env) do
    raise CompileError,
      file: source.file,
      line: source.line,
      description: "Procedure handler must be a function with arity 2, got: #{inspect(handler)}"
  end

  defp validate_input!(%{input: nil}, _env), do: :ok
  defp validate_input!(%{input: _schema}, _env) do
    # TODO: Validate it's a Zoi schema when Zoi is integrated
    :ok
  end

  defp validate_output!(%{output: nil}, _env), do: :ok
  defp validate_output!(%{output: _schema}, _env) do
    # TODO: Validate it's a Zoi schema when Zoi is integrated
    :ok
  end

  defp validate_route!(%{route: nil}, _env), do: :ok
  defp validate_route!(%{route: %{method: method, path: path}}, _env)
    when method in [:get, :post, :put, :patch, :delete] and is_binary(path), do: :ok
  defp validate_route!(%{route: route, __source__: source}, _env) do
    raise CompileError,
      file: source.file,
      line: source.line,
      description: "Invalid route definition: #{inspect(route)}"
  end

  # Schema introspection for code generation

  @doc "Returns the JSON Schema for the input"
  def input_json_schema(%__MODULE__{input: nil}), do: nil
  def input_json_schema(%__MODULE__{input: schema}) do
    # TODO: Use Zoi.to_json_schema when available
    # For now, return placeholder
    %{"type" => "object"}
  end

  @doc "Returns the JSON Schema for the output"
  def output_json_schema(%__MODULE__{output: nil}), do: nil
  def output_json_schema(%__MODULE__{output: schema}) do
    # TODO: Use Zoi.to_json_schema when available
    %{"type" => "object"}
  end

  @doc "Returns a unique identifier for this procedure"
  def procedure_id(%__MODULE__{name: name}), do: Atom.to_string(name)
end
```

---

## 2. Zrpc.Procedure.MetaParser

Parses the `meta do ... end` block at compile time.

```elixir
# lib/zrpc/procedure/meta_parser.ex
defmodule Zrpc.Procedure.MetaParser do
  @moduledoc """
  Parses meta block AST at compile time to extract metadata.

  Supports:
    meta do
      description "User retrieval"
      tags ["users", "public"]
      examples [%{id: "123"}]
      deprecated "Use get_user_v2 instead"
    end

  Or inline:
    meta description: "User retrieval", tags: ["users"]
  """

  @doc """
  Parses a meta block or keyword list into a map.
  """
  def parse({:__block__, _, statements}) do
    Enum.reduce(statements, %{}, &parse_statement/2)
  end

  def parse(single_statement) when is_tuple(single_statement) do
    parse_statement(single_statement, %{})
  end

  def parse(keyword_list) when is_list(keyword_list) do
    Enum.into(keyword_list, %{})
  end

  # Parse individual statements

  defp parse_statement({:description, _, [text]}, acc) when is_binary(text) do
    Map.put(acc, :description, text)
  end

  defp parse_statement({:tags, _, [list]}, acc) when is_list(list) do
    Map.put(acc, :tags, list)
  end

  defp parse_statement({:examples, _, [list]}, acc) when is_list(list) do
    Map.put(acc, :examples, list)
  end

  defp parse_statement({:example, _, [value]}, acc) do
    # Single example - wrap in list
    existing = Map.get(acc, :examples, [])
    Map.put(acc, :examples, existing ++ [value])
  end

  defp parse_statement({:deprecated, _, [value]}, acc) do
    Map.put(acc, :deprecated, value)
  end

  defp parse_statement({:summary, _, [text]}, acc) when is_binary(text) do
    # Alias for short description (OpenAPI compat)
    Map.put(acc, :summary, text)
  end

  defp parse_statement({:operation_id, _, [id]}, acc) when is_binary(id) do
    # Custom operation ID for OpenAPI
    Map.put(acc, :operation_id, id)
  end

  defp parse_statement(_unknown, acc) do
    # Ignore unknown statements
    acc
  end
end
```

---

## 3. Zrpc.Procedure.Compiler

The `@before_compile` hook that generates introspection functions.

```elixir
# lib/zrpc/procedure/compiler.ex
defmodule Zrpc.Procedure.Compiler do
  @moduledoc """
  Compile-time hook that:
  1. Validates all procedure definitions
  2. Generates introspection functions
  3. Optimizes procedure lookup with compile-time indexing
  """

  alias Zrpc.Procedure.Definition

  defmacro __before_compile__(env) do
    procedures = Module.get_attribute(env.module, :zrpc_procedures) || []

    # Reverse because @accumulate prepends
    procedures = Enum.reverse(procedures)

    # Validate all procedures at compile time
    Enum.each(procedures, fn proc ->
      Definition.validate!(proc, env)
    end)

    # Build lookup indexes
    procedures_by_name = build_name_index(procedures)
    queries = filter_by_type(procedures, :query)
    mutations = filter_by_type(procedures, :mutation)
    subscriptions = filter_by_type(procedures, :subscription)
    procedure_names = Enum.map(procedures, & &1.name)

    quote do
      @doc """
      Returns all procedures defined in this module.
      """
      @spec __zrpc_procedures__() :: [Zrpc.Procedure.Definition.t()]
      def __zrpc_procedures__ do
        unquote(Macro.escape(procedures))
      end

      @doc """
      Returns a procedure by name, or nil if not found.
      """
      @spec __zrpc_procedure__(atom()) :: Zrpc.Procedure.Definition.t() | nil
      def __zrpc_procedure__(name) when is_atom(name) do
        unquote(Macro.escape(procedures_by_name))[name]
      end

      @doc """
      Returns all query procedures.
      """
      @spec __zrpc_queries__() :: [Zrpc.Procedure.Definition.t()]
      def __zrpc_queries__ do
        unquote(Macro.escape(queries))
      end

      @doc """
      Returns all mutation procedures.
      """
      @spec __zrpc_mutations__() :: [Zrpc.Procedure.Definition.t()]
      def __zrpc_mutations__ do
        unquote(Macro.escape(mutations))
      end

      @doc """
      Returns all subscription procedures.
      """
      @spec __zrpc_subscriptions__() :: [Zrpc.Procedure.Definition.t()]
      def __zrpc_subscriptions__ do
        unquote(Macro.escape(subscriptions))
      end

      @doc """
      Returns all procedure names.
      """
      @spec __zrpc_procedure_names__() :: [atom()]
      def __zrpc_procedure_names__ do
        unquote(procedure_names)
      end

      @doc """
      Checks if a procedure with the given name exists.
      """
      @spec __zrpc_has_procedure__?(atom()) :: boolean()
      def __zrpc_has_procedure__?(name) when is_atom(name) do
        name in unquote(procedure_names)
      end

      @doc """
      Returns the module name (for router registration).
      """
      @spec __zrpc_module__() :: module()
      def __zrpc_module__, do: __MODULE__
    end
  end

  defp build_name_index(procedures) do
    Enum.into(procedures, %{}, fn p -> {p.name, p} end)
  end

  defp filter_by_type(procedures, type) do
    Enum.filter(procedures, &(&1.type == type))
  end
end
```

---

## 4. Zrpc.Procedure (Main DSL Module)

The main module that provides the DSL macros.

```elixir
# lib/zrpc/procedure.ex
defmodule Zrpc.Procedure do
  @moduledoc """
  DSL for defining RPC procedures.

  ## Usage

      defmodule MyApp.Procedures.Users do
        use Zrpc.Procedure

        query :get_user do
          meta do
            description "Get a user by ID"
            tags ["users"]
          end

          input Zoi.object(%{
            id: Zoi.string() |> Zoi.uuid()
          })

          output Zoi.object(%{
            id: Zoi.string(),
            name: Zoi.string(),
            email: Zoi.string()
          })

          handler fn %{id: id}, ctx ->
            case MyApp.Users.get_user(id) do
              nil -> {:error, :not_found}
              user -> {:ok, user}
            end
          end
        end

        mutation :create_user do
          input Zoi.object(%{
            name: Zoi.string() |> Zoi.min(1),
            email: Zoi.email()
          })

          handler fn input, ctx ->
            MyApp.Users.create(input)
          end
        end

        subscription :user_updated do
          input Zoi.object(%{user_id: Zoi.string()})

          handler fn %{user_id: user_id}, ctx ->
            # Return a Stream or subscribe to PubSub
          end
        end
      end

  ## Procedure Types

  - `query` - Read operations, idempotent, can use GET
  - `mutation` - Write operations, not idempotent, uses POST
  - `subscription` - Real-time updates via WebSocket

  ## Available Directives

  - `input/1` - Zoi schema for input validation
  - `output/1` - Zoi schema for output validation
  - `handler/1` - Function that handles the procedure
  - `meta/1` - Metadata for documentation/OpenAPI
  - `route/1` - Optional REST route mapping
  """

  alias Zrpc.Procedure.{Definition, MetaParser}

  defmacro __using__(_opts) do
    quote do
      import Zrpc.Procedure, only: [
        query: 2,
        mutation: 2,
        subscription: 2,
        middleware: 1,
        middleware: 2
      ]

      Module.register_attribute(__MODULE__, :zrpc_procedures, accumulate: true)
      @before_compile Zrpc.Procedure.Compiler
    end
  end

  @doc """
  Defines a query procedure (read operation).

  Queries are idempotent and can be safely retried. They may use
  HTTP GET when exposed via REST routes.
  """
  defmacro query(name, do: block) do
    define_procedure(:query, name, block, __CALLER__)
  end

  @doc """
  Defines a mutation procedure (write operation).

  Mutations are not idempotent and should use HTTP POST
  when exposed via REST routes.
  """
  defmacro mutation(name, do: block) do
    define_procedure(:mutation, name, block, __CALLER__)
  end

  @doc """
  Defines a subscription procedure (real-time updates).

  Subscriptions are long-lived connections that push updates
  to clients. They require WebSocket transport.
  """
  defmacro subscription(name, do: block) do
    define_procedure(:subscription, name, block, __CALLER__)
  end

  # Private: Generate the procedure definition code
  defp define_procedure(type, name, block, caller) do
    # Note: __MODULE__ is evaluated at expansion time in the quote block
    source_base = %{file: caller.file, line: caller.line}

    quote do
      # Initialize temporary module attributes for this procedure
      Module.put_attribute(__MODULE__, :zrpc_current_input, nil)
      Module.put_attribute(__MODULE__, :zrpc_current_output, nil)
      Module.put_attribute(__MODULE__, :zrpc_current_handler, nil)
      Module.put_attribute(__MODULE__, :zrpc_current_meta, %{})
      Module.put_attribute(__MODULE__, :zrpc_current_route, nil)
      Module.put_attribute(__MODULE__, :zrpc_current_middleware, [])

      # Import directive macros for this block only
      import Zrpc.Procedure, only: [
        input: 1,
        output: 1,
        handler: 1,
        meta: 1,
        route: 1,
        middleware: 1,
        middleware: 2
      ]

      # Execute the block (this will set the module attributes)
      unquote(block)

      # Build and register the procedure definition
      @zrpc_procedures %Definition{
        name: unquote(name),
        type: unquote(type),
        input: Module.get_attribute(__MODULE__, :zrpc_current_input),
        output: Module.get_attribute(__MODULE__, :zrpc_current_output),
        handler: Module.get_attribute(__MODULE__, :zrpc_current_handler),
        meta: Module.get_attribute(__MODULE__, :zrpc_current_meta),
        route: Module.get_attribute(__MODULE__, :zrpc_current_route),
        middleware: Module.get_attribute(__MODULE__, :zrpc_current_middleware) |> Enum.reverse(),
        __source__: Map.put(unquote(Macro.escape(source_base)), :module, __MODULE__)
      }

      # Clean up temporary attributes
      Module.delete_attribute(__MODULE__, :zrpc_current_input)
      Module.delete_attribute(__MODULE__, :zrpc_current_output)
      Module.delete_attribute(__MODULE__, :zrpc_current_handler)
      Module.delete_attribute(__MODULE__, :zrpc_current_meta)
      Module.delete_attribute(__MODULE__, :zrpc_current_route)
      Module.delete_attribute(__MODULE__, :zrpc_current_middleware)
    end
  end

  @doc """
  Defines the input schema for validation.

  ## Example

      input Zoi.object(%{
        id: Zoi.string() |> Zoi.uuid(),
        name: Zoi.string() |> Zoi.optional()
      })
  """
  defmacro input(schema) do
    quote do
      Module.put_attribute(__MODULE__, :zrpc_current_input, unquote(schema))
    end
  end

  @doc """
  Defines the output schema for validation.

  Output validation is optional but recommended for:
  - Ensuring you don't leak sensitive data
  - Generating accurate TypeScript types
  - Runtime output verification (can be disabled in prod)

  ## Example

      output Zoi.object(%{
        id: Zoi.string(),
        name: Zoi.string(),
        email: Zoi.string()
      })
  """
  defmacro output(schema) do
    quote do
      Module.put_attribute(__MODULE__, :zrpc_current_output, unquote(schema))
    end
  end

  @doc """
  Defines the handler function.

  The handler receives:
  - `input` - Validated input (empty map if no input schema)
  - `ctx` - Zrpc.Context with request metadata and assigns

  Must return:
  - `{:ok, data}` - Success with response data
  - `{:error, atom}` - Error with code (e.g., :not_found)
  - `{:error, atom, message}` - Error with code and message
  - `{:error, %Zrpc.Error{}}` - Structured error

  ## Supported Styles

  ### Style A: Anonymous Function (inline)

      handler fn %{id: id}, ctx ->
        case MyApp.Users.get_user(id) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end
      end

  ### Style B: Function Reference

      handler &MyApp.Handlers.Users.get_user/2

  ### Style C: Implicit (no handler directive)

  If no `handler` is specified, the procedure name becomes a function
  that you must define in the same module:

      query :get_user do
        input Zoi.object(%{id: Zoi.string()})
        # No handler directive
      end

      # Define the handler as a regular function:
      def get_user(%{id: id}, ctx) do
        {:ok, MyApp.Users.get(id)}
      end

  """
  defmacro handler(func) do
    quote do
      Module.put_attribute(__MODULE__, :zrpc_current_handler, unquote(func))
    end
  end

  @doc """
  Defines metadata for documentation and OpenAPI generation.

  ## Block syntax

      meta do
        description "Get a user by their unique ID"
        tags ["users", "public"]
        examples [%{id: "550e8400-e29b-41d4-a716-446655440000"}]
        deprecated "Use get_user_v2 instead"
      end

  ## Inline syntax

      meta description: "Get a user", tags: ["users"]
  """
  defmacro meta(do: block) do
    parsed = MetaParser.parse(block)
    quote do
      Module.put_attribute(__MODULE__, :zrpc_current_meta, unquote(Macro.escape(parsed)))
    end
  end

  defmacro meta(keyword_list) when is_list(keyword_list) do
    quote do
      Module.put_attribute(__MODULE__, :zrpc_current_meta, Enum.into(unquote(keyword_list), %{}))
    end
  end

  @doc """
  Defines an optional REST route mapping.

  When set, this procedure can also be accessed via traditional
  REST endpoints in addition to the RPC endpoint.

  ## Example

      route method: :get, path: "/users/{id}"
      route method: :post, path: "/users"

  Path parameters (e.g., `{id}`) are automatically extracted
  and merged into the input.
  """
  defmacro route(opts) when is_list(opts) do
    quote do
      Module.put_attribute(__MODULE__, :zrpc_current_route, %{
        method: Keyword.fetch!(unquote(opts), :method),
        path: Keyword.fetch!(unquote(opts), :path)
      })
    end
  end

  @doc """
  Adds inline middleware to this procedure.

  Middleware is executed in order, before the handler.
  Procedure-level middleware runs AFTER router-level middleware.

  ## Example

      query :admin_action do
        middleware MyApp.Middleware.RequireAdmin
        middleware MyApp.Middleware.AuditLog, level: :info

        handler fn input, ctx ->
          # ctx.assigns.current_user is guaranteed to be an admin
          {:ok, do_admin_action(input)}
        end
      end
  """
  defmacro middleware(module) when is_atom(module) do
    quote do
      current = Module.get_attribute(__MODULE__, :zrpc_current_middleware)
      Module.put_attribute(__MODULE__, :zrpc_current_middleware, [unquote(module) | current])
    end
  end

  defmacro middleware(module, opts) when is_atom(module) and is_list(opts) do
    quote do
      current = Module.get_attribute(__MODULE__, :zrpc_current_middleware)
      Module.put_attribute(__MODULE__, :zrpc_current_middleware, [{unquote(module), unquote(opts)} | current])
    end
  end
end
```

---

## 5. Zrpc.Procedure.Executor

Executes procedures with input/output validation, exception handling, and middleware.

```elixir
# lib/zrpc/procedure/executor.ex
defmodule Zrpc.Procedure.Executor do
  @moduledoc """
  Executes a procedure with:
  - Before hooks
  - Input validation (via Zoi)
  - Inline middleware chain
  - Handler execution with try/catch
  - Output validation (via Zoi, configurable)
  - After hooks
  - Telemetry events throughout
  """

  alias Zrpc.Procedure.Definition
  alias Zrpc.Context

  require Logger

  @doc """
  Executes a procedure with the given input and context.

  Returns:
  - `{:ok, validated_output}` on success
  - `{:error, error}` on failure

  ## Execution Flow

  1. Emit `[:zrpc, :procedure, :start]` telemetry
  2. Run before hooks
  3. Validate input against schema
  4. Run inline middleware chain
  5. Execute handler (wrapped in try/catch)
  6. Validate output against schema (if enabled)
  7. Run after hooks
  8. Emit `[:zrpc, :procedure, :stop]` or `[:zrpc, :procedure, :exception]` telemetry

  ## Options

  - `:before_hooks` - List of `{module, function}` tuples called before validation
  - `:after_hooks` - List of `{module, function}` tuples called after output
  - `:validate_output` - Boolean to override output validation (overrides procedure meta and global config)

  ## Telemetry Events

  - `[:zrpc, :procedure, :start]` - Emitted when procedure execution starts
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{procedure: atom, type: atom, module: module}`

  - `[:zrpc, :procedure, :stop]` - Emitted on successful completion
    - Measurements: `%{duration: integer}` (native time units)
    - Metadata: `%{procedure: atom, type: atom, module: module}`

  - `[:zrpc, :procedure, :exception]` - Emitted on error
    - Measurements: `%{duration: integer}`
    - Metadata: `%{procedure: atom, type: atom, module: module, kind: atom, reason: term}`
  """
  @spec execute(Definition.t(), map(), Context.t(), keyword()) ::
    {:ok, term()} | {:error, term()}
  def execute(%Definition{} = proc, raw_input, %Context{} = ctx, opts \\ []) do
    start_time = System.monotonic_time()
    metadata = build_telemetry_metadata(proc)

    :telemetry.execute(
      [:zrpc, :procedure, :start],
      %{system_time: System.system_time()},
      metadata
    )

    result =
      with {:ok, ctx} <- run_before_hooks(opts[:before_hooks] || [], ctx, raw_input, proc),
           {:ok, input} <- validate_input(proc, raw_input),
           {:ok, ctx} <- run_middleware_chain(proc.middleware, ctx),
           {:ok, output} <- execute_handler(proc, input, ctx),
           {:ok, validated_output} <- maybe_validate_output(proc, output, opts),
           {:ok, final_output} <- run_after_hooks(opts[:after_hooks] || [], ctx, validated_output, proc) do
        {:ok, final_output}
      end

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, _} ->
        :telemetry.execute(
          [:zrpc, :procedure, :stop],
          %{duration: duration},
          metadata
        )

      {:error, error} ->
        :telemetry.execute(
          [:zrpc, :procedure, :exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: error})
        )
    end

    result
  end

  defp build_telemetry_metadata(%{name: name, type: type, __source__: %{module: module}}) do
    %{procedure: name, type: type, module: module}
  end

  # Before Hooks - called before input validation
  # Hook signature: hook(ctx, raw_input, procedure) :: {:ok, ctx} | {:error, reason}

  defp run_before_hooks([], ctx, _raw_input, _proc), do: {:ok, ctx}

  defp run_before_hooks([{mod, fun} | rest], ctx, raw_input, proc) do
    case apply(mod, fun, [ctx, raw_input, proc]) do
      {:ok, ctx} -> run_before_hooks(rest, ctx, raw_input, proc)
      {:error, _} = error -> error
    end
  end

  # After Hooks - called after output validation
  # Hook signature: hook(ctx, output, procedure) :: {:ok, output} | {:error, reason}

  defp run_after_hooks([], _ctx, output, _proc), do: {:ok, output}

  defp run_after_hooks([{mod, fun} | rest], ctx, output, proc) do
    case apply(mod, fun, [ctx, output, proc]) do
      {:ok, output} -> run_after_hooks(rest, ctx, output, proc)
      {:error, _} = error -> error
    end
  end

  # Input Validation

  defp validate_input(%{input: nil}, raw_input) do
    # No schema defined, pass through (default to empty map if nil)
    {:ok, raw_input || %{}}
  end

  defp validate_input(%{input: schema}, raw_input) do
    case Zoi.parse(schema, raw_input || %{}) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, format_validation_error(errors)}
    end
  end

  # Middleware Chain

  defp run_middleware_chain([], ctx), do: {:ok, ctx}

  defp run_middleware_chain([middleware | rest], ctx) do
    {mod, opts} = normalize_middleware(middleware)

    case apply(mod, :call, [ctx, opts, fn ctx -> run_middleware_chain(rest, ctx) end]) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, _} = error -> error
    end
  end

  defp normalize_middleware({mod, opts}) when is_atom(mod) and is_list(opts) do
    {mod, mod.init(opts)}
  end

  defp normalize_middleware(mod) when is_atom(mod) do
    {mod, mod.init([])}
  end

  # Handler Execution with Exception Handling

  defp execute_handler(%{handler: nil, name: name, __source__: %{module: module}}, input, ctx) do
    # Implicit handler: call the module function with procedure name
    execute_handler_fn(&apply(module, name, [&1, &2]), name, input, ctx)
  end

  defp execute_handler(%{handler: handler, name: name}, input, ctx) do
    execute_handler_fn(handler, name, input, ctx)
  end

  defp execute_handler_fn(handler, name, input, ctx) do
    try do
      case handler.(input, ctx) do
        {:ok, result} -> {:ok, result}
        {:error, code} when is_atom(code) -> {:error, %{code: code}}
        {:error, code, message} -> {:error, %{code: code, message: message}}
        {:error, %{} = error} -> {:error, error}
        other ->
          Logger.warning("[Zrpc] Procedure #{name} returned unexpected value: #{inspect(other)}")
          {:error, %{code: :internal_error, message: "Unexpected handler return value"}}
      end
    rescue
      e ->
        Logger.error("[Zrpc] Procedure #{name} raised exception: #{Exception.format(:error, e, __STACKTRACE__)}")
        {:error, %{
          code: :internal_error,
          message: "Internal server error",
          # Don't expose internal details in production
          __exception__: if(Mix.env() != :prod, do: Exception.format(:error, e, __STACKTRACE__))
        }}
    end
  end

  # Output Validation (Configurable)
  #
  # Output validation can be controlled at three levels (precedence order):
  # 1. Per-call option: execute(proc, input, ctx, validate_output: false)
  # 2. Per-procedure meta: meta validate_output: false
  # 3. Global config: config :zrpc, validate_output: true (default)

  defp maybe_validate_output(proc, output, opts) do
    if should_validate_output?(proc, opts) do
      validate_output(proc, output)
    else
      {:ok, output}
    end
  end

  defp should_validate_output?(proc, opts) do
    cond do
      # Per-call option takes highest precedence
      Keyword.has_key?(opts, :validate_output) ->
        Keyword.get(opts, :validate_output)

      # Per-procedure meta takes second precedence
      Map.has_key?(proc.meta, :validate_output) ->
        proc.meta[:validate_output]

      # Global config is the fallback (defaults to true)
      true ->
        Application.get_env(:zrpc, :validate_output, true)
    end
  end

  defp validate_output(%{output: nil}, output) do
    # No schema defined, pass through
    {:ok, output}
  end

  defp validate_output(%{output: schema, name: name}, output) do
    case Zoi.parse(schema, output) do
      {:ok, validated} ->
        {:ok, validated}
      {:error, errors} ->
        # Log the error but don't expose internal schema mismatch to client
        Logger.error("[Zrpc] Procedure #{name} output validation failed: #{inspect(errors)}")
        Logger.error("[Zrpc] Output was: #{inspect(output)}")
        {:error, %{code: :internal_error, message: "Response validation failed"}}
    end
  end

  # Error Formatting

  defp format_validation_error(errors) do
    %{
      code: :validation_error,
      message: "Validation failed",
      details: format_zoi_errors(errors)
    }
  end

  defp format_zoi_errors(errors) when is_list(errors) do
    Enum.reduce(errors, %{}, fn error, acc ->
      path = error[:path] || []
      key = Enum.join(path, ".")
      messages = Map.get(acc, key, [])
      Map.put(acc, key, messages ++ [error[:message]])
    end)
  end

  defp format_zoi_errors(errors), do: errors
end
```

---

## 6. Zrpc.Context

Transport-agnostic request context.

```elixir
# lib/zrpc/context.ex
defmodule Zrpc.Context do
  @moduledoc """
  Request context that flows through the middleware chain.

  The context is transport-agnostic, meaning the same middleware
  can work with both HTTP (Plug.Conn) and WebSocket (Phoenix.Socket).

  ## Fields

  - `transport` - `:http` or `:websocket`
  - `conn` - The Plug.Conn (only for HTTP)
  - `socket` - The Phoenix.Socket (only for WebSocket)
  - `assigns` - User-defined data (like current_user)
  - `metadata` - Request metadata (request_id, timing, etc.)
  - `procedure_path` - Full path like "users.get_user"
  - `procedure_type` - :query, :mutation, or :subscription
  """

  @type transport :: :http | :websocket

  @type t :: %__MODULE__{
    transport: transport(),
    conn: Plug.Conn.t() | nil,
    socket: Phoenix.Socket.t() | nil,
    assigns: map(),
    metadata: map(),
    procedure_path: String.t() | nil,
    procedure_type: :query | :mutation | :subscription | nil
  }

  defstruct [
    :transport,
    :conn,
    :socket,
    :procedure_path,
    :procedure_type,
    assigns: %{},
    metadata: %{}
  ]

  @doc """
  Creates a context from a Plug.Conn (HTTP transport).
  """
  @spec from_conn(Plug.Conn.t(), keyword()) :: t()
  def from_conn(conn, opts \\ []) do
    %__MODULE__{
      transport: :http,
      conn: conn,
      socket: nil,
      assigns: %{},
      metadata: %{
        request_id: get_request_id(conn),
        started_at: System.monotonic_time(:microsecond),
        remote_ip: format_ip(conn.remote_ip)
      },
      procedure_path: opts[:path],
      procedure_type: opts[:type]
    }
  end

  @doc """
  Creates a context from a Phoenix.Socket (WebSocket transport).
  """
  @spec from_socket(Phoenix.Socket.t(), keyword()) :: t()
  def from_socket(socket, opts \\ []) do
    %__MODULE__{
      transport: :websocket,
      conn: nil,
      socket: socket,
      assigns: extract_socket_assigns(socket),
      metadata: %{
        socket_id: socket.id,
        started_at: System.monotonic_time(:microsecond),
        channel_topic: socket.topic
      },
      procedure_path: opts[:path],
      procedure_type: opts[:type]
    }
  end

  @doc """
  Creates an empty context (useful for testing).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      transport: Keyword.get(opts, :transport, :http),
      conn: nil,
      socket: nil,
      assigns: Keyword.get(opts, :assigns, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      procedure_path: opts[:path],
      procedure_type: opts[:type]
    }
  end

  @doc """
  Assigns a key-value pair to the context.

  ## Example

      ctx = Zrpc.Context.assign(ctx, :current_user, user)
  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{} = ctx, key, value) when is_atom(key) do
    %{ctx | assigns: Map.put(ctx.assigns, key, value)}
  end

  @doc """
  Assigns multiple key-value pairs to the context.

  ## Example

      ctx = Zrpc.Context.assign(ctx, current_user: user, org_id: org.id)
  """
  @spec assign(t(), keyword()) :: t()
  def assign(%__MODULE__{} = ctx, keyword_list) when is_list(keyword_list) do
    %{ctx | assigns: Map.merge(ctx.assigns, Map.new(keyword_list))}
  end

  @doc """
  Gets a value from assigns.
  """
  @spec get_assign(t(), atom(), term()) :: term()
  def get_assign(%__MODULE__{assigns: assigns}, key, default \\ nil) do
    Map.get(assigns, key, default)
  end

  @doc """
  Adds metadata to the context.
  """
  @spec put_metadata(t(), atom(), term()) :: t()
  def put_metadata(%__MODULE__{} = ctx, key, value) when is_atom(key) do
    %{ctx | metadata: Map.put(ctx.metadata, key, value)}
  end

  @doc """
  Gets metadata from the context.
  """
  @spec get_metadata(t(), atom(), term()) :: term()
  def get_metadata(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  @doc """
  Returns the elapsed time in microseconds since context creation.
  """
  @spec elapsed_us(t()) :: non_neg_integer()
  def elapsed_us(%__MODULE__{metadata: %{started_at: started_at}}) do
    System.monotonic_time(:microsecond) - started_at
  end

  def elapsed_us(_), do: 0

  @doc """
  Returns the elapsed time in milliseconds.
  """
  @spec elapsed_ms(t()) :: float()
  def elapsed_ms(ctx), do: elapsed_us(ctx) / 1000

  @doc """
  Checks if this is an HTTP context.
  """
  @spec http?(t()) :: boolean()
  def http?(%__MODULE__{transport: :http}), do: true
  def http?(_), do: false

  @doc """
  Checks if this is a WebSocket context.
  """
  @spec websocket?(t()) :: boolean()
  def websocket?(%__MODULE__{transport: :websocket}), do: true
  def websocket?(_), do: false

  # Private helpers

  defp get_request_id(conn) do
    case Plug.Conn.get_req_header(conn, "x-request-id") do
      [id | _] -> id
      [] -> generate_request_id()
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp format_ip(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end
  defp format_ip(ip), do: inspect(ip)

  defp extract_socket_assigns(socket) do
    # Extract commonly needed assigns from socket
    socket.assigns
    |> Map.take([:current_user, :user_id, :token, :locale])
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
end
```

---

## 6. Testing

Create test files to verify the DSL works correctly.

```elixir
# test/zrpc/procedure_test.exs
defmodule Zrpc.ProcedureTest do
  use ExUnit.Case, async: true

  defmodule TestProcedures do
    use Zrpc.Procedure

    query :get_user do
      meta do
        description "Get a user by ID"
        tags ["users"]
      end

      input %{id: :string}  # Placeholder until Zoi integrated
      output %{id: :string, name: :string}

      handler fn %{id: id}, _ctx ->
        {:ok, %{id: id, name: "Test User"}}
      end
    end

    mutation :create_user do
      meta description: "Create a new user", tags: ["users"]

      input %{name: :string, email: :string}

      handler fn input, _ctx ->
        {:ok, Map.put(input, :id, "generated-id")}
      end
    end

    query :with_route do
      route method: :get, path: "/items/{id}"
      handler fn input, _ctx -> {:ok, input} end
    end

    subscription :user_updates do
      input %{user_id: :string}
      handler fn _input, _ctx -> {:ok, :stream} end
    end
  end

  describe "__zrpc_procedures__/0" do
    test "returns all procedures" do
      procedures = TestProcedures.__zrpc_procedures__()
      assert length(procedures) == 4
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
      assert length(queries) == 2
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

  describe "procedure execution" do
    test "handler can be called directly" do
      proc = TestProcedures.__zrpc_procedure__(:get_user)
      ctx = Zrpc.Context.new()

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
  end
end

# test/zrpc/context_test.exs
defmodule Zrpc.ContextTest do
  use ExUnit.Case, async: true

  alias Zrpc.Context

  describe "new/1" do
    test "creates empty context" do
      ctx = Context.new()
      assert ctx.transport == :http
      assert ctx.assigns == %{}
    end

    test "accepts options" do
      ctx = Context.new(transport: :websocket, assigns: %{user: "test"})
      assert ctx.transport == :websocket
      assert ctx.assigns.user == "test"
    end
  end

  describe "assign/3" do
    test "assigns a value" do
      ctx = Context.new() |> Context.assign(:user_id, 123)
      assert Context.get_assign(ctx, :user_id) == 123
    end
  end

  describe "assign/2 with keyword list" do
    test "assigns multiple values" do
      ctx = Context.new() |> Context.assign(user_id: 123, role: :admin)
      assert Context.get_assign(ctx, :user_id) == 123
      assert Context.get_assign(ctx, :role) == :admin
    end
  end

  describe "elapsed_ms/1" do
    test "returns elapsed time" do
      ctx = Context.new(metadata: %{started_at: System.monotonic_time(:microsecond)})
      Process.sleep(10)
      elapsed = Context.elapsed_ms(ctx)
      assert elapsed >= 10
    end
  end

  describe "transport checks" do
    test "http?/1" do
      assert Context.http?(Context.new(transport: :http))
      refute Context.http?(Context.new(transport: :websocket))
    end

    test "websocket?/1" do
      assert Context.websocket?(Context.new(transport: :websocket))
      refute Context.websocket?(Context.new(transport: :http))
    end
  end
end
```

---

## Implementation Checklist

- [ ] Create `lib/zrpc/procedure/definition.ex`
- [ ] Create `lib/zrpc/procedure/meta_parser.ex`
- [ ] Create `lib/zrpc/procedure/compiler.ex`
- [ ] Create `lib/zrpc/procedure/executor.ex`
- [ ] Create `lib/zrpc/procedure.ex`
- [ ] Create `lib/zrpc/context.ex`
- [ ] Create `test/zrpc/procedure_test.exs`
- [ ] Create `test/zrpc/context_test.exs`
- [ ] Create `test/zrpc/procedure/executor_test.exs`
- [ ] Run tests: `mix test test/zrpc/`
- [ ] Verify compilation with sample procedures

---

## Design Decisions

1. **Handler Signature**: Always arity 2 - handler receives `(input, ctx)`, input is `%{}` if no schema defined

2. **Handler Styles**: Multiple styles supported with auto-detection:
   - **Style A**: Anonymous function `handler fn input, ctx -> ... end`
   - **Style B**: Function reference `handler &Mod.fun/2`
   - **Style C**: Implicit - no handler directive, define `def procedure_name(input, ctx)`

3. **Inline Middleware**: Supported - procedures can define their own middleware:
   ```elixir
   query :admin_only do
     middleware MyApp.Middleware.RequireAdmin
     middleware MyApp.Middleware.AuditLog
     handler fn input, ctx -> ... end
   end
   ```

4. **Output Validation**: Configurable at three levels (precedence order):
   - Per-call: `execute(proc, input, ctx, validate_output: false)`
   - Per-procedure: `meta validate_output: false`
   - Global: `config :zrpc, validate_output: true` (default: true)

5. **Exception Handling**: Catch and convert - wrap handler execution in try/catch, convert exceptions to `{:error, :internal_error, message}`

6. **Shared Schemas**: Users can define reusable schemas any way they prefer:
   ```elixir
   # Module attribute
   @user_schema Zoi.object(%{...})

   # Function
   def user_schema, do: Zoi.object(%{...})

   # Separate module
   MyApp.Schemas.User.schema()
   ```

---

## Context Design

The `Zrpc.Context` is designed to be **transport-agnostic** - the same context flows through middleware and handlers regardless of whether the request came via HTTP or WebSocket.

### Design Principles

1. **Transport Abstraction**: Handlers and middleware don't need to know or care about the underlying transport
2. **Immutable Updates**: Context modifications return new contexts (functional style)
3. **Layered Data**: Clear separation between assigns (user data) and metadata (request data)
4. **Testing Friendly**: Easy to create contexts for unit tests with `Context.new/1`

### Context Fields

| Field | Type | Description |
|-------|------|-------------|
| `transport` | `:http \| :websocket` | Transport type for conditional logic |
| `conn` | `Plug.Conn.t() \| nil` | Raw connection (HTTP only) |
| `socket` | `Phoenix.Socket.t() \| nil` | Raw socket (WebSocket only) |
| `assigns` | `map()` | User-defined data (current_user, etc.) |
| `metadata` | `map()` | Request metadata (request_id, timing, etc.) |
| `procedure_path` | `String.t() \| nil` | Full path like "users.get_user" |
| `procedure_type` | `atom() \| nil` | :query, :mutation, or :subscription |

### Accessing Request Data

For transport-specific data, provide helper functions that work across transports:

```elixir
defmodule Zrpc.Context do
  @doc "Get a request header (HTTP) or socket param (WebSocket)"
  def get_header(ctx, key, default \\ nil)

  def get_header(%{transport: :http, conn: conn}, key, default) do
    case Plug.Conn.get_req_header(conn, key) do
      [value | _] -> value
      [] -> default
    end
  end

  def get_header(%{transport: :websocket, socket: socket}, key, default) do
    # WebSocket: look in socket.assigns or params
    Map.get(socket.assigns, String.to_atom(key), default)
  end

  @doc "Get the client IP address"
  def remote_ip(%{transport: :http, conn: conn}), do: conn.remote_ip
  def remote_ip(%{transport: :websocket, socket: socket}) do
    socket.assigns[:remote_ip] || {0, 0, 0, 0}
  end

  @doc "Get all headers/params as a map"
  def headers(%{transport: :http, conn: conn}) do
    Enum.into(conn.req_headers, %{})
  end

  def headers(%{transport: :websocket, socket: socket}) do
    socket.assigns[:headers] || %{}
  end
end
```

### Context Usage Patterns

```elixir
# In middleware
def call(ctx, _opts, next) do
  case get_current_user(ctx) do
    {:ok, user} ->
      ctx = Context.assign(ctx, :current_user, user)
      next.(ctx)
    {:error, _} ->
      {:error, :unauthorized}
  end
end

# In handler
handler fn input, ctx ->
  user = Context.get_assign(ctx, :current_user)
  # ... use user
end

# Conditional transport logic (rare)
handler fn input, ctx ->
  case ctx.transport do
    :http -> handle_http(input, ctx.conn)
    :websocket -> handle_ws(input, ctx.socket)
  end
end
```

### Test Context Creation

```elixir
# Simple test context
ctx = Context.new()

# With user assigned
ctx = Context.new(assigns: %{current_user: %{id: "1", role: :admin}})

# Simulating WebSocket
ctx = Context.new(transport: :websocket, assigns: %{socket_id: "abc"})
```

---

## Middleware Integration

Middleware in Zrpc follows a "continuation-passing" style similar to Plug but adapted for the RPC context.

### Middleware Behaviour

```elixir
# lib/zrpc/middleware.ex
defmodule Zrpc.Middleware do
  @moduledoc """
  Behaviour for Zrpc middleware.

  Middleware can:
  - Modify the context before passing to the next middleware/handler
  - Short-circuit the chain by returning an error
  - Transform or wrap the response (via the continuation)
  """

  @type opts :: term()
  @type next :: (Zrpc.Context.t() -> {:ok, Zrpc.Context.t()} | {:error, term()})

  @doc """
  Initialize middleware options at compile time.
  Called once when the middleware is registered.
  """
  @callback init(keyword()) :: opts()

  @doc """
  Execute the middleware.

  Receives:
  - `ctx` - The current context
  - `opts` - Options returned from init/1
  - `next` - Function to call the next middleware in chain

  Must return:
  - `{:ok, ctx}` - Success, pass modified context forward
  - `{:error, reason}` - Short-circuit with error
  """
  @callback call(Zrpc.Context.t(), opts(), next()) ::
    {:ok, Zrpc.Context.t()} | {:error, term()}

  @optional_callbacks [init: 1]

  defmacro __using__(_opts) do
    quote do
      @behaviour Zrpc.Middleware

      def init(opts), do: opts

      defoverridable init: 1
    end
  end
end
```

### Middleware Execution Order

Middleware executes in this order:

1. **Router-level middleware** (defined in `Zrpc.Router`)
2. **Scope-level middleware** (defined in router `scope do ... end`)
3. **Procedure-level middleware** (defined inline in procedure)
4. **Handler execution**

```
Request → Router MW → Scope MW → Procedure MW → Handler
                                                   ↓
Response ← Router MW ← Scope MW ← Procedure MW ← Result
```

### Example Middleware

```elixir
defmodule MyApp.Middleware.RequireAuth do
  use Zrpc.Middleware

  @impl true
  def call(ctx, _opts, next) do
    case extract_and_verify_token(ctx) do
      {:ok, user} ->
        ctx = Zrpc.Context.assign(ctx, :current_user, user)
        next.(ctx)
      {:error, reason} ->
        {:error, :unauthorized, reason}
    end
  end

  defp extract_and_verify_token(ctx) do
    with {:ok, token} <- get_auth_token(ctx),
         {:ok, claims} <- verify_jwt(token),
         {:ok, user} <- load_user(claims["sub"]) do
      {:ok, user}
    end
  end

  defp get_auth_token(ctx) do
    case Zrpc.Context.get_header(ctx, "authorization") do
      "Bearer " <> token -> {:ok, token}
      _ -> {:error, "Missing authorization header"}
    end
  end
end

defmodule MyApp.Middleware.RateLimit do
  use Zrpc.Middleware

  @impl true
  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, 100),
      window_ms: Keyword.get(opts, :window_ms, 60_000)
    }
  end

  @impl true
  def call(ctx, opts, next) do
    key = rate_limit_key(ctx)

    case check_rate_limit(key, opts) do
      :ok -> next.(ctx)
      {:error, :rate_limited} -> {:error, :too_many_requests}
    end
  end

  defp rate_limit_key(ctx) do
    # Use user ID if authenticated, otherwise IP
    case Zrpc.Context.get_assign(ctx, :current_user) do
      %{id: user_id} -> "user:#{user_id}"
      nil -> "ip:#{inspect(Zrpc.Context.remote_ip(ctx))}"
    end
  end
end

defmodule MyApp.Middleware.AuditLog do
  use Zrpc.Middleware

  @impl true
  def init(opts) do
    %{level: Keyword.get(opts, :level, :info)}
  end

  @impl true
  def call(ctx, opts, next) do
    # Log before
    log_request(ctx, opts)

    # Execute and capture result
    result = next.(ctx)

    # Log after
    log_response(ctx, result, opts)

    result
  end
end
```

### Middleware with Options

```elixir
# Without options - uses defaults
middleware MyApp.Middleware.RateLimit

# With options - passed to init/1
middleware MyApp.Middleware.RateLimit, limit: 50, window_ms: 30_000

# Multiple middleware on same procedure
query :sensitive_action do
  middleware MyApp.Middleware.RequireAuth
  middleware MyApp.Middleware.RequireAdmin
  middleware MyApp.Middleware.AuditLog, level: :warn

  handler fn input, ctx ->
    # ctx.assigns.current_user is guaranteed to be an admin
    {:ok, perform_action(input)}
  end
end
```

### Middleware vs Plugs

| Feature | Zrpc Middleware | Plug |
|---------|-----------------|------|
| Works with HTTP | ✅ | ✅ |
| Works with WebSocket | ✅ | ❌ |
| Access to RPC context | ✅ | ❌ |
| Continuation style | `next.(ctx)` | `call(conn)` |
| Per-procedure | ✅ | ❌ (per-route only) |

Use Plugs for HTTP-specific concerns (CORS, compression). Use Zrpc Middleware for RPC-specific concerns (auth, rate limiting, logging).

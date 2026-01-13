# Zrpc Guide

This guide provides a comprehensive walkthrough of Zrpc, a modern RPC framework for Elixir. Define your API once and use it as the single source of truth for validation, TypeScript client generation, and OpenAPI documentation.

## Table of Contents

- [Getting Started](#getting-started)
- [Procedures](#procedures)
- [Router](#router)
- [Context](#context)
- [Middleware](#middleware)
- [Error Handling](#error-handling)
- [Batch Execution](#batch-execution)
- [Telemetry](#telemetry)
- [Configuration](#configuration)
- [Integration Patterns](#integration-patterns)

## Getting Started

### Installation

Add `zrpc` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:zrpc, "~> 0.1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

### Project Structure

A typical Zrpc application has this structure:

```
lib/
├── my_app/
│   ├── procedures/
│   │   ├── users.ex       # User-related procedures
│   │   └── posts.ex       # Post-related procedures
│   ├── middleware/
│   │   ├── auth.ex        # Authentication middleware
│   │   └── logger.ex      # Request logging
│   └── router.ex          # Main router
```

### Your First Procedure

Create a simple procedure module:

```elixir
defmodule MyApp.Procedures.Greet do
  use Zrpc.Procedure

  query :hello do
    input Zoi.object(%{
      name: Zoi.string() |> Zoi.min(1)
    })

    output Zoi.object(%{
      message: Zoi.string()
    })

    handler fn %{name: name}, _ctx ->
      {:ok, %{message: "Hello, #{name}!"}}
    end
  end
end
```

Create a router:

```elixir
defmodule MyApp.Router do
  use Zrpc.Router

  procedures MyApp.Procedures.Greet, at: "greet"
end
```

Execute the procedure:

```elixir
ctx = Zrpc.Context.new()
{:ok, result} = Zrpc.Router.call(MyApp.Router, "greet.hello", %{name: "World"}, ctx)
# => {:ok, %{message: "Hello, World!"}}
```

## Procedures

Procedures are the building blocks of your API. They come in three types:

- **query** - Read operations, idempotent, safe to retry
- **mutation** - Write operations, may have side effects
- **subscription** - Real-time updates via WebSocket

### Defining Procedures

```elixir
defmodule MyApp.Procedures.Users do
  use Zrpc.Procedure

  query :get do
    input Zoi.object(%{
      id: Zoi.string() |> Zoi.uuid()
    })

    output Zoi.object(%{
      id: Zoi.string(),
      name: Zoi.string(),
      email: Zoi.string()
    })

    handler fn %{id: id}, ctx ->
      case MyApp.Users.get(id) do
        nil -> {:error, :not_found}
        user -> {:ok, user}
      end
    end
  end

  mutation :create do
    input Zoi.object(%{
      name: Zoi.string() |> Zoi.min(1),
      email: Zoi.string() |> Zoi.email()
    })

    handler fn input, ctx ->
      MyApp.Users.create(input)
    end
  end

  subscription :updates do
    input Zoi.object(%{
      user_id: Zoi.string()
    })

    handler fn %{user_id: user_id}, ctx ->
      # Subscribe to real-time updates
      {:ok, :subscribed}
    end
  end
end
```

### Available Directives

| Directive | Required | Description |
|-----------|----------|-------------|
| `input` | No | Zoi schema for input validation |
| `output` | No | Zoi schema for output validation |
| `handler` | No* | Function that handles the procedure |
| `meta` | No | Metadata for documentation |
| `route` | No | REST route mapping |
| `middleware` | No | Procedure-level middleware |

*If no handler is defined, you must implement a function with the procedure name.

### Input and Output Schemas

Schemas are defined using [Zoi](https://github.com/wavezync/zoi):

```elixir
query :search do
  input Zoi.object(%{
    query: Zoi.string() |> Zoi.min(1),
    page: Zoi.integer() |> Zoi.min(1) |> Zoi.default(1),
    per_page: Zoi.integer() |> Zoi.min(1) |> Zoi.max(100) |> Zoi.default(20),
    filters: Zoi.object(%{
      status: Zoi.enum(["active", "inactive"]) |> Zoi.optional(),
      created_after: Zoi.string() |> Zoi.datetime() |> Zoi.optional()
    }) |> Zoi.optional()
  })

  output Zoi.object(%{
    results: Zoi.array(Zoi.object(%{
      id: Zoi.string(),
      title: Zoi.string()
    })),
    total: Zoi.integer(),
    page: Zoi.integer()
  })

  handler fn input, _ctx ->
    {:ok, MyApp.Search.execute(input)}
  end
end
```

### Handler Styles

#### Style A: Inline Anonymous Function

```elixir
query :get_user do
  handler fn %{id: id}, ctx ->
    {:ok, get_user(id)}
  end
end
```

#### Style B: Function Reference

```elixir
query :get_user do
  handler &MyApp.Handlers.Users.get/2
end
```

#### Style C: Implicit Handler

If no `handler` directive is specified, define a function with the procedure name:

```elixir
query :get_user do
  input Zoi.object(%{id: Zoi.string()})
end

def get_user(%{id: id}, ctx) do
  {:ok, MyApp.Users.get(id)}
end
```

### Metadata

Add documentation and tags for API documentation:

```elixir
query :get_user do
  meta do
    description "Retrieves a user by their unique identifier"
    tags ["users", "public"]
    examples [%{id: "550e8400-e29b-41d4-a716-446655440000"}]
  end

  # ... rest of procedure
end

# Or inline syntax:
query :get_user do
  meta description: "Get a user", tags: ["users"]
  # ...
end
```

### Procedure-Level Middleware

Add middleware that applies only to a specific procedure:

```elixir
mutation :admin_action do
  middleware MyApp.Middleware.RequireAdmin
  middleware MyApp.Middleware.AuditLog, level: :info

  handler fn input, ctx ->
    {:ok, perform_admin_action(input)}
  end
end
```

## Router

The router organizes procedures into a hierarchical namespace tree.

### Basic Registration

```elixir
defmodule MyApp.Router do
  use Zrpc.Router

  procedures MyApp.Procedures.Users, at: "users"
  procedures MyApp.Procedures.Posts, at: "posts"
end
```

This creates paths like:
- `users.get`, `users.create`
- `posts.list`, `posts.get`

### Router-Level Middleware

Middleware at the router level applies to all procedures:

```elixir
defmodule MyApp.Router do
  use Zrpc.Router

  middleware MyApp.Middleware.RequestId
  middleware MyApp.Middleware.Logger
  middleware MyApp.Middleware.Auth

  procedures MyApp.Procedures.Users, at: "users"
end
```

### Scopes

Group procedures with a path prefix and optional middleware:

```elixir
defmodule MyApp.Router do
  use Zrpc.Router

  middleware MyApp.Middleware.Logger

  # Public procedures
  procedures MyApp.Procedures.Public, at: "public"

  # Admin-only procedures
  scope "admin" do
    middleware MyApp.Middleware.RequireAdmin

    procedures MyApp.Procedures.AdminUsers, at: "users"
    procedures MyApp.Procedures.AdminSettings, at: "settings"

    # Super admin only
    scope "super" do
      middleware MyApp.Middleware.RequireSuperAdmin

      procedures MyApp.Procedures.SuperAdmin, at: "actions"
    end
  end
end
```

This creates:
- `public.list` (Logger)
- `admin.users.list` (Logger + RequireAdmin)
- `admin.super.actions.delete` (Logger + RequireAdmin + RequireSuperAdmin)

### Skipping Middleware

Exclude specific middleware for certain procedures:

```elixir
# Health check doesn't need authentication
procedures MyApp.Procedures.Health, at: "health", skip_middleware: [MyApp.Middleware.Auth]
```

### Path Aliases

Create alternative names for backwards compatibility:

```elixir
defmodule MyApp.Router do
  use Zrpc.Router

  procedures MyApp.Procedures.Users, at: "users"

  # Support old path names
  path_alias "getUser", to: "users.get"

  # Mark deprecated aliases
  path_alias "user.fetch", to: "users.get", deprecated: true
end
```

Deprecated aliases emit telemetry events when used.

### Introspection

Query the router at runtime:

```elixir
# List all registered paths
MyApp.Router.__zrpc_paths__()
# => ["users.get", "users.create", "admin.users.list", ...]

# Get entry for a specific path
MyApp.Router.__zrpc_entry__("users.get")
# => %Zrpc.Router.Entry{...}

# List all aliases
MyApp.Router.__zrpc_aliases__()
# => ["getUser", "user.fetch"]

# Resolve an alias
MyApp.Router.__zrpc_alias__("getUser")
# => %Zrpc.Router.Alias{from: "getUser", to: "users.get", deprecated: false}
```

## Context

The context carries request information through the middleware chain and handlers.

### Creating Context

```elixir
# From Plug.Conn (HTTP)
ctx = Zrpc.Context.from_conn(conn)

# From Phoenix.Socket (WebSocket)
ctx = Zrpc.Context.from_socket(socket)

# For testing
ctx = Zrpc.Context.new()
ctx = Zrpc.Context.new(assigns: %{current_user: user})
```

### Working with Assigns

Assigns store user-defined data like the current user:

```elixir
# Set a single value
ctx = Zrpc.Context.assign(ctx, :current_user, user)

# Set multiple values
ctx = Zrpc.Context.assign(ctx, current_user: user, org_id: org.id)

# Get a value
user = Zrpc.Context.get_assign(ctx, :current_user)
role = Zrpc.Context.get_assign(ctx, :role, :guest)  # with default

# Access directly
user = ctx.assigns[:current_user]
```

### Metadata

Metadata stores request-level information:

```elixir
# Add metadata
ctx = Zrpc.Context.put_metadata(ctx, :trace_id, trace_id)

# Get metadata
request_id = Zrpc.Context.get_metadata(ctx, :request_id)
```

Built-in metadata (when using `from_conn` or `from_socket`):
- `request_id` - Unique request identifier
- `started_at` - Monotonic timestamp
- `remote_ip` - Client IP address (HTTP only)
- `socket_id` - Socket identifier (WebSocket only)
- `channel_topic` - Channel topic (WebSocket only)

### Transport Helpers

```elixir
# Check transport type
Zrpc.Context.http?(ctx)       # => true/false
Zrpc.Context.websocket?(ctx)  # => true/false

# Get elapsed time
Zrpc.Context.elapsed_ms(ctx)  # => 123.45 (milliseconds)
Zrpc.Context.elapsed_us(ctx)  # => 123450 (microseconds)
```

## Middleware

Middleware intercepts procedure calls for cross-cutting concerns.

### Basic Middleware

```elixir
defmodule MyApp.Middleware.Logger do
  use Zrpc.Middleware

  @impl true
  def call(ctx, _opts, next) do
    start = System.monotonic_time()
    result = next.(ctx)
    duration = System.monotonic_time() - start

    Logger.info("#{ctx.procedure_path} completed in #{duration}ns")
    result
  end
end
```

### Middleware with Options

```elixir
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
    user_id = ctx.assigns[:current_user_id]

    case check_rate_limit(user_id, opts.limit, opts.window_ms) do
      :ok -> next.(ctx)
      {:error, :exceeded} -> {:error, :too_many_requests}
    end
  end
end

# Usage:
middleware MyApp.Middleware.RateLimit, limit: 50, window_ms: 10_000
```

### Short-Circuiting

Middleware can stop the chain by returning an error:

```elixir
defmodule MyApp.Middleware.RequireAuth do
  use Zrpc.Middleware

  @impl true
  def call(ctx, _opts, next) do
    case get_current_user(ctx) do
      {:ok, user} ->
        ctx = Zrpc.Context.assign(ctx, :current_user, user)
        next.(ctx)  # Continue to next middleware/handler

      {:error, _} ->
        {:error, :unauthorized}  # Stop here, don't call next
    end
  end
end
```

### Execution Order

Middleware executes in this order:

```
Request
   │
   ▼
Router Middleware (first registered → last)
   │
   ▼
Scope Middleware (outer scope → inner scope)
   │
   ▼
Procedure Middleware (first registered → last)
   │
   ▼
Handler
   │
   ▼
Response (bubbles back through middleware)
```

### Common Patterns

#### Authentication

```elixir
defmodule MyApp.Middleware.Auth do
  use Zrpc.Middleware

  @impl true
  def call(ctx, _opts, next) do
    with {:ok, token} <- extract_token(ctx),
         {:ok, user} <- verify_token(token) do
      ctx = Zrpc.Context.assign(ctx, :current_user, user)
      next.(ctx)
    else
      _ -> {:error, %{code: :unauthorized, message: "Invalid or missing token"}}
    end
  end

  defp extract_token(%{conn: conn}) when not is_nil(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :no_token}
    end
  end
end
```

#### Request Logging

```elixir
defmodule MyApp.Middleware.RequestLogger do
  use Zrpc.Middleware
  require Logger

  @impl true
  def call(ctx, _opts, next) do
    Logger.info("[RPC] #{ctx.procedure_path} started")

    case next.(ctx) do
      {:ok, _} = result ->
        Logger.info("[RPC] #{ctx.procedure_path} succeeded in #{Zrpc.Context.elapsed_ms(ctx)}ms")
        result

      {:error, error} = result ->
        Logger.warn("[RPC] #{ctx.procedure_path} failed: #{inspect(error)}")
        result
    end
  end
end
```

## Error Handling

### Handler Return Formats

Handlers can return errors in multiple formats:

```elixir
# Simple atom code
{:error, :not_found}
# => %{code: :not_found}

# Code with message
{:error, :validation_failed, "Email already exists"}
# => %{code: :validation_failed, message: "Email already exists"}

# Structured error map
{:error, %{code: :custom_error, message: "Details", field: "email"}}
# => %{code: :custom_error, message: "Details", field: "email"}
```

### Validation Errors

Input validation errors are automatically formatted:

```elixir
{:error, %{
  code: :validation_error,
  message: "Validation failed",
  details: %{
    "email" => ["must be a valid email"],
    "name" => ["is required", "must be at least 1 character"]
  }
}}
```

### Exception Handling

Exceptions in handlers are caught and converted to internal errors:

```elixir
# Handler raises an exception
handler fn input, ctx ->
  raise "Something went wrong"
end

# Returns:
{:error, %{
  code: :internal_error,
  message: "Internal server error"
}}
```

Enable exception details in development:

```elixir
# config/dev.exs
config :zrpc, include_exception_details: true
```

## Batch Execution

Execute multiple procedures in parallel:

```elixir
ctx = Zrpc.Context.new()

results = Zrpc.Router.batch(MyApp.Router, [
  {"users.get", %{id: "123"}},
  {"users.get", %{id: "456"}},
  {"posts.list", %{user_id: "123"}}
], ctx)

# => [
#   {:ok, %{id: "123", name: "Alice"}},
#   {:ok, %{id: "456", name: "Bob"}},
#   {:ok, [%{id: "1", title: "..."}]}
# ]
```

### Options

```elixir
Zrpc.Router.batch(router, calls, ctx,
  max_concurrency: 10,    # Maximum parallel executions (default: 10)
  timeout: 30_000,        # Per-procedure timeout in ms (default: 30_000)
  max_batch_size: 50      # Maximum calls per batch (default: 50)
)
```

### Handling Mixed Results

```elixir
results = Zrpc.Router.batch(MyApp.Router, calls, ctx)

Enum.each(results, fn
  {:ok, data} ->
    IO.puts("Success: #{inspect(data)}")

  {:error, %{code: :timeout}} ->
    IO.puts("Procedure timed out")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end)
```

## Telemetry

Zrpc emits telemetry events for observability.

### Available Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:zrpc, :procedure, :start]` | `system_time` | `procedure`, `type`, `module` |
| `[:zrpc, :procedure, :stop]` | `duration` | `procedure`, `type`, `module` |
| `[:zrpc, :procedure, :exception]` | `duration` | `procedure`, `type`, `module`, `kind`, `reason` |
| `[:zrpc, :router, :lookup, :start]` | `system_time` | `router`, `path` |
| `[:zrpc, :router, :lookup, :stop]` | `duration` | `router`, `path`, `found` |
| `[:zrpc, :router, :batch, :start]` | `system_time`, `batch_size` | `router`, `paths` |
| `[:zrpc, :router, :batch, :stop]` | `duration`, `success_count`, `error_count` | `router` |
| `[:zrpc, :router, :alias, :resolved]` | — | `router`, `from`, `to`, `deprecated` |

### Attaching Handlers

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def setup do
    :telemetry.attach_many(
      "zrpc-logger",
      [
        [:zrpc, :procedure, :stop],
        [:zrpc, :procedure, :exception]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:zrpc, :procedure, :stop], %{duration: duration}, metadata, _config) do
    Logger.info("#{metadata.procedure} completed in #{System.convert_time_unit(duration, :native, :millisecond)}ms")
  end

  def handle_event([:zrpc, :procedure, :exception], %{duration: duration}, metadata, _config) do
    Logger.error("#{metadata.procedure} failed: #{inspect(metadata.reason)}")
  end
end
```

### Metrics with Telemetry.Metrics

```elixir
defmodule MyApp.Telemetry do
  import Telemetry.Metrics

  def metrics do
    [
      counter("zrpc.procedure.stop.count", tags: [:procedure, :type]),
      summary("zrpc.procedure.stop.duration", unit: {:native, :millisecond}, tags: [:procedure]),
      counter("zrpc.procedure.exception.count", tags: [:procedure, :kind]),
      counter("zrpc.router.alias.resolved.count", tags: [:deprecated])
    ]
  end
end
```

## Configuration

### Application Config

```elixir
# config/config.exs
config :zrpc,
  # Validate procedure output against schema (default: true)
  validate_output: true,

  # Include exception details in error responses (default: false)
  # WARNING: Only enable in development!
  include_exception_details: false
```

### Per-Procedure Config

Disable output validation for specific procedures:

```elixir
query :large_report do
  meta validate_output: false  # Skip output validation

  handler fn input, ctx ->
    {:ok, generate_large_report(input)}
  end
end
```

### Per-Call Config

Override settings for specific calls:

```elixir
Zrpc.Router.call(MyApp.Router, "reports.generate", input, ctx,
  validate_output: false
)
```

## Integration Patterns

### Phoenix Controller

```elixir
defmodule MyAppWeb.RpcController do
  use MyAppWeb, :controller

  def call(conn, %{"path" => path, "input" => input}) do
    ctx = Zrpc.Context.from_conn(conn)

    case Zrpc.Router.call(MyApp.Router, path, input, ctx) do
      {:ok, result} ->
        json(conn, %{result: result})

      {:error, %{code: :not_found} = error} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: error})

      {:error, %{code: :unauthorized}} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: :unauthorized, message: "Unauthorized"}})

      {:error, error} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: error})
    end
  end

  def batch(conn, %{"calls" => calls}) do
    ctx = Zrpc.Context.from_conn(conn)
    parsed_calls = Enum.map(calls, fn %{"path" => path, "input" => input} -> {path, input} end)

    results = Zrpc.Router.batch(MyApp.Router, parsed_calls, ctx)
    json(conn, %{results: results})
  end
end
```

### Phoenix Channel

```elixir
defmodule MyAppWeb.RpcChannel do
  use MyAppWeb, :channel

  def handle_in("call", %{"path" => path, "input" => input}, socket) do
    ctx = Zrpc.Context.from_socket(socket)

    case Zrpc.Router.call(MyApp.Router, path, input, ctx) do
      {:ok, result} ->
        {:reply, {:ok, %{result: result}}, socket}

      {:error, error} ->
        {:reply, {:error, %{error: error}}, socket}
    end
  end
end
```

### Plug Integration

```elixir
defmodule MyApp.Plug.Rpc do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    router = Keyword.fetch!(opts, :router)
    {:ok, body, conn} = read_body(conn)
    %{"path" => path, "input" => input} = Jason.decode!(body)

    ctx = Zrpc.Context.from_conn(conn)

    case Zrpc.Router.call(router, path, input, ctx) do
      {:ok, result} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{result: result}))

      {:error, error} ->
        status = error_to_status(error)
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{error: error}))
    end
  end

  defp error_to_status(%{code: :not_found}), do: 404
  defp error_to_status(%{code: :unauthorized}), do: 401
  defp error_to_status(%{code: :validation_error}), do: 422
  defp error_to_status(_), do: 400
end
```

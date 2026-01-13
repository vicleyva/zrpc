# Zrpc

[![Hex.pm](https://img.shields.io/hexpm/v/zrpc.svg)](https://hex.pm/packages/zrpc)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/zrpc.svg)](https://hex.pm/packages/zrpc)
[![CI](https://github.com/wavezync/zrpc/actions/workflows/ci.yml/badge.svg)](https://github.com/wavezync/zrpc/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/zrpc.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/zrpc)

A modern RPC framework for Elixir with a clean DSL, middleware system, and hierarchical routing. Define your API once, generate TypeScript clients and OpenAPI specs automatically.

Zrpc provides a type-safe, transport-agnostic way to define and execute remote procedure calls. It's inspired by tRPC and designed to work seamlessly with Phoenix, Plug, or any Elixir application. Your procedure definitions serve as the **single source of truth** for validation, documentation, and client generation.

## Features

- **Single Source of Truth** - Generate TypeScript clients and OpenAPI specs from your procedure definitions
- **Clean DSL** for defining queries, mutations, and subscriptions
- **Schema Validation** with [Zoi](https://github.com/wavezync/zoi) for input/output validation
- **Middleware System** with compile-time optimization
- **Hierarchical Router** with namespacing, scopes, and aliases
- **Transport Agnostic** - works with HTTP, WebSocket, or custom transports
- **Telemetry Integration** for observability
- **Batch Execution** with configurable concurrency

## Installation

Add `zrpc` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:zrpc, "~> 0.0.0-alpha"}
  ]
end
```

## Quick Start

### 1. Define Procedures

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

    handler fn %{id: id}, _ctx ->
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

    handler fn input, _ctx ->
      MyApp.Users.create(input)
    end
  end
end
```

### 2. Create a Router

```elixir
defmodule MyApp.Router do
  use Zrpc.Router

  # Global middleware
  middleware MyApp.Middleware.Logger
  middleware MyApp.Middleware.Auth

  # Register procedures at namespaces
  procedures MyApp.Procedures.Users, at: "users"
  procedures MyApp.Procedures.Posts, at: "posts"

  # Scoped routes with additional middleware
  scope "admin" do
    middleware MyApp.Middleware.RequireAdmin

    procedures MyApp.Procedures.Admin, at: "actions"
  end
end
```

This creates paths like:
- `users.get`, `users.create`
- `posts.list`, `posts.get`
- `admin.actions.delete_user`

### 3. Execute Procedures

```elixir
# Create a context
ctx = Zrpc.Context.new()

# Single call
{:ok, user} = Zrpc.Router.call(MyApp.Router, "users.get", %{id: "123"}, ctx)

# Batch call
results = Zrpc.Router.batch(MyApp.Router, [
  {"users.get", %{id: "123"}},
  {"posts.list", %{user_id: "123"}}
], ctx)
```

## Core Concepts

### Procedures

Procedures are the building blocks of your API. They come in three types:

- **query** - Read operations (idempotent)
- **mutation** - Write operations
- **subscription** - Real-time updates

```elixir
defmodule MyApp.Procedures.Example do
  use Zrpc.Procedure

  query :fetch_data do
    input Zoi.object(%{id: Zoi.string()})
    handler fn %{id: id}, ctx -> {:ok, %{id: id}} end
  end

  mutation :update_data do
    input Zoi.object(%{id: Zoi.string(), data: Zoi.any()})
    handler fn input, ctx -> {:ok, input} end
  end

  subscription :watch_data do
    input Zoi.object(%{id: Zoi.string()})
    handler fn %{id: id}, ctx ->
      # Return a stream or subscription
    end
  end
end
```

### Context

The context carries request information through the middleware chain and into handlers:

```elixir
# Create from Plug.Conn
ctx = Zrpc.Context.from_conn(conn)

# Create from Phoenix.Socket
ctx = Zrpc.Context.from_socket(socket)

# Add custom assigns
ctx = Zrpc.Context.assign(ctx, :current_user, user)

# Access in handlers
handler fn input, ctx ->
  user = ctx.assigns[:current_user]
  # ...
end
```

### Middleware

Middleware intercepts procedure calls for cross-cutting concerns:

```elixir
defmodule MyApp.Middleware.Auth do
  use Zrpc.Middleware

  @impl true
  def call(ctx, _opts, next) do
    case get_current_user(ctx) do
      {:ok, user} ->
        ctx = Zrpc.Context.assign(ctx, :current_user, user)
        next.(ctx)
      {:error, _} ->
        {:error, :unauthorized}
    end
  end
end
```

### Router

The router organizes procedures into a hierarchical namespace:

```elixir
defmodule MyApp.Router do
  use Zrpc.Router

  # Global middleware
  middleware MyApp.Middleware.RequestId

  # Simple registration
  procedures MyApp.Procedures.Public, at: "public"

  # Nested scopes
  scope "api" do
    scope "v1" do
      procedures MyApp.Procedures.V1.Users, at: "users"
    end
  end

  # Path aliases for backwards compatibility
  path_alias "getUser", to: "api.v1.users.get", deprecated: true
end
```

## Error Handling

Handlers can return errors in multiple formats:

```elixir
# Simple atom code
{:error, :not_found}

# Code with message
{:error, :validation_failed, "Email is invalid"}

# Structured error
{:error, %{code: :custom_error, message: "Details", extra: "data"}}
```

Validation errors are automatically formatted:

```elixir
{:error, %{
  code: :validation_error,
  message: "Validation failed",
  details: %{
    "email" => ["must be a valid email"]
  }
}}
```

## Telemetry Events

Zrpc emits telemetry events for observability:

```elixir
# Procedure events
[:zrpc, :procedure, :start]
[:zrpc, :procedure, :stop]
[:zrpc, :procedure, :exception]

# Router events
[:zrpc, :router, :lookup, :start]
[:zrpc, :router, :lookup, :stop]
[:zrpc, :router, :batch, :start]
[:zrpc, :router, :batch, :stop]
[:zrpc, :router, :alias, :resolved]
```

## Configuration

```elixir
# config/config.exs
config :zrpc,
  # Validate procedure output against schema (default: true)
  validate_output: true,

  # Include exception details in error responses (default: false)
  include_exception_details: false
```

## Documentation

- [Full Guide](guides/guide.md) - Comprehensive usage guide
- [HexDocs](https://hexdocs.pm/zrpc) - API documentation

## License

MIT License - see [LICENSE](LICENSE) for details.
å
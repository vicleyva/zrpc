# Phase 2: Router DSL Implementation

## Overview

Create a Router DSL that organizes procedures into a hierarchical namespace tree with support for scoped middleware and nested namespaces.

## Target Usage

```elixir
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
```

This creates procedure paths like:
- `users.get_user`, `users.create_user`
- `posts.get_post`, `posts.list_posts`
- `admin.users.list_all`, `admin.settings.update`

---

## Files to Create

| File | Purpose |
|------|---------|
| `lib/zrpc/router.ex` | Main Router DSL with macros |
| `lib/zrpc/router/compiler.ex` | `@before_compile` hook for validation & code generation |
| `lib/zrpc/router/entry.ex` | Struct representing a registered procedure entry |
| `lib/zrpc/router/alias.ex` | Struct representing a path alias |
| `test/zrpc/router_test.exs` | Router DSL tests |

---

## Path Resolution Strategy

### Path Format

**Decision: Dot notation** - Aligns with tRPC conventions and feels natural for RPC.

| Format | Example | Pros | Cons |
|--------|---------|------|------|
| **Dot notation** | `users.get_user` | tRPC standard, clean, object-like | Can't use dots in names |
| **Slash notation** | `users/get_user` | REST-like, familiar | Feels like URL, not RPC |

### Path Construction

A full path is constructed as: `{scope_prefix}.{namespace}.{procedure_name}`

```
scope "admin" do
  procedures UserProcs, at: "users"
    -> procedure :get has path "admin.users.get"
end
```

**Path segments:**
1. **Scope prefix** - From nested `scope` blocks (e.g., `admin`, `admin.super`)
2. **Namespace** - From `procedures ... at: "namespace"` (e.g., `users`)
3. **Procedure name** - The atom name converted to string (e.g., `get_user`)

### Internal vs External Path Representation

| Aspect | Internal (Elixir) | External (JSON/HTTP) |
|--------|-------------------|----------------------|
| Storage | List of atoms `[:admin, :users, :get_user]` | String `"admin.users.get_user"` |
| Lookup | Pattern match on list | String split then match |
| Why | Fast matching, no string parsing | JSON-friendly, URL-friendly |

**Entry struct stores both:**
```elixir
%Entry{
  path: "admin.users.get_user",        # External string format
  path_segments: [:admin, :users, :get_user],  # Internal atom list
  ...
}
```

### Path Lookup Strategy

**Decision: Pattern-matched function clauses O(1)** - Elixir compiler optimizes this well, no runtime map allocation, easy to generate.

```elixir
# Compile-time generated clauses
def __zrpc_entry__("users.get_user"), do: %Entry{...}
def __zrpc_entry__("users.create_user"), do: %Entry{...}
def __zrpc_entry__(_), do: nil
```

### Path Validation Rules

1. **No empty segments**: `"users..get"` is invalid
2. **No leading/trailing dots**: `".users.get"` and `"users.get."` are invalid
3. **Valid characters**: `a-z`, `0-9`, `_` (lowercase snake_case)
4. **No reserved words**: Avoid `__` prefix (reserved for introspection)
5. **Case sensitivity**: Paths are case-sensitive, but we enforce lowercase

### Path Collision Detection

At compile time, detect and error on:

```elixir
# Same path from different registrations
procedures UserProcs, at: "users"    # has :get procedure -> users.get
procedures OtherProcs, at: "users"   # also has :get -> COLLISION!
```

**Error message:**
```
** (CompileError) lib/my_router.ex:15: Duplicate procedure path "users.get"
  - First defined in MyApp.Procedures.Users at lib/my_router.ex:8
  - Also defined in MyApp.Procedures.Other at lib/my_router.ex:15
```

---

## Path Aliases

Support defining alternative names for the same procedure for backwards compatibility or convenience:

```elixir
defmodule MyApp.Router do
  use Zrpc.Router

  procedures MyApp.Procedures.Users, at: "users"

  # Alias for backwards compatibility after rename
  alias "users.get_user", to: "users.get"

  # Alias for convenience/shorthand
  alias "getUser", to: "users.get"
end
```

**Alias struct:**
```elixir
%Alias{
  from: "users.get_user",    # The alias path
  to: "users.get",           # The canonical path
  deprecated: false          # Optional: mark as deprecated
}
```

**Resolution behavior:**
1. First lookup canonical path
2. If not found, check aliases
3. If alias found, resolve to canonical and execute
4. Optionally emit telemetry/log for deprecated alias usage

**Validation:**
- Alias target must exist
- Alias name must not conflict with existing paths
- No circular aliases

---

## Middleware Composition

### Middleware Layers

Middleware applies at multiple levels, executed in order:

```
Request
   │
   ▼
┌─────────────────────────────┐
│  Router Middleware (global) │  ← Defined at router root level
└─────────────────────────────┘
   │
   ▼
┌─────────────────────────────┐
│  Scope Middleware (nested)  │  ← Defined in scope blocks (inherits parent)
└─────────────────────────────┘
   │
   ▼
┌─────────────────────────────┐
│  Procedure Middleware       │  ← Defined inline in procedure
└─────────────────────────────┘
   │
   ▼
┌─────────────────────────────┐
│  Handler                    │
└─────────────────────────────┘
   │
   ▼
Response (bubbles back up through middleware)
```

### Middleware Chain Construction

**At compile time**, the Router.Compiler pre-computes the full chain for each entry:

```elixir
# Given this router:
defmodule MyRouter do
  use Zrpc.Router

  middleware GlobalLogger          # [1]
  middleware GlobalRequestId       # [2]

  scope "admin" do
    middleware RequireAuth         # [3]
    middleware AuditLog            # [4]

    scope "super" do
      middleware RequireSuperAdmin # [5]

      procedures SuperAdminProcs, at: "actions"
      # SuperAdminProcs has procedure with: middleware RateLimit  # [6]
    end
  end
end

# For path "admin.super.actions.delete_user":
# Chain = [GlobalLogger, GlobalRequestId, RequireAuth, AuditLog, RequireSuperAdmin, RateLimit]
```

### Middleware Override/Skip

Support skipping inherited middleware for specific procedures:

```elixir
scope "admin" do
  middleware RequireAuth

  procedures AdminProcs, at: "secure"

  # Public health check doesn't need auth
  procedures HealthProcs, at: "health", skip_middleware: [RequireAuth]
end
```

---

## Error Handling

### Router-Level Errors

| Error | Code | When |
|-------|------|------|
| Procedure not found | `:not_found` | Path doesn't exist and no alias |
| Invalid path format | `:invalid_path` | Path contains invalid characters |
| Method not allowed | `:method_not_allowed` | Calling mutation as query (future HTTP) |

### Error Response Format

```elixir
%{
  code: :not_found,
  message: "Procedure not found: users.unknown",
  path: "users.unknown",           # Include path for debugging
  suggestions: ["users.get", "users.list"]  # Optional: similar paths
}
```

### Router.call/5 Implementation

```elixir
def call(router_module, path, input, ctx, opts \\ []) do
  with :ok <- validate_path_format(path),
       {:ok, entry} <- resolve_path(router_module, path),
       ctx <- Context.with_procedure(ctx, entry.path, entry.procedure.type) do

    Executor.execute(entry.procedure, input, ctx,
      Keyword.put(opts, :middleware, entry.middleware))
  else
    {:error, :invalid_path} ->
      {:error, %{code: :invalid_path, message: "Invalid path format: #{path}"}}

    {:error, :not_found} ->
      {:error, %{
        code: :not_found,
        message: "Procedure not found: #{path}",
        path: path,
        suggestions: find_similar_paths(router_module, path)
      }}
  end
end

defp validate_path_format(path) do
  if Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/, path) do
    :ok
  else
    {:error, :invalid_path}
  end
end

defp find_similar_paths(router_module, path) do
  router_module.__zrpc_paths__()
  |> Enum.filter(&String.jaro_distance(&1, path) > 0.7)
  |> Enum.take(3)
end
```

### Telemetry Events

```elixir
# Router lookup
[:zrpc, :router, :lookup, :start]
[:zrpc, :router, :lookup, :stop]

# Alias resolution
[:zrpc, :router, :alias, :resolved]

# Batch execution
[:zrpc, :router, :batch, :start]
[:zrpc, :router, :batch, :stop]
```

---

## Batch Execution

### Use Cases

1. **Performance**: Reduce HTTP round-trips
2. **Atomicity**: Execute related procedures together
3. **Client convenience**: Fetch multiple resources in one call

### Batch API

```elixir
# Single call (existing)
Router.call(MyRouter, "users.get", %{id: "123"}, ctx)

# Batch call (new)
Router.batch(MyRouter, [
  {"users.get", %{id: "123"}},
  {"posts.list", %{user_id: "123"}},
  {"notifications.count", %{}}
], ctx, opts)

# Returns list of results in same order
[
  {:ok, %{id: "123", name: "Alice"}},
  {:ok, [%{id: "p1", title: "Post 1"}, ...]},
  {:error, %{code: :unauthorized}}
]
```

### Batch Implementation

```elixir
def batch(router_module, calls, ctx, opts \\ []) do
  max_concurrency = Keyword.get(opts, :max_concurrency, 10)
  timeout = Keyword.get(opts, :timeout, 30_000)

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
end
```

### Batch Options

```elixir
Router.batch(MyRouter, calls, ctx,
  max_concurrency: 5,       # Max parallel executions
  timeout: 10_000,          # Per-procedure timeout (ms)
  stop_on_error: false,     # Continue even if one fails
  max_batch_size: 50        # Maximum calls per batch
)
```

---

## Implementation Details

### 1. `Zrpc.Router.Entry`

```elixir
defstruct [
  :path,           # Full dotted path: "admin.users.get_user"
  :path_segments,  # List of atoms: [:admin, :users, :get_user]
  :procedure,      # The Zrpc.Procedure.Definition struct
  :middleware,     # Combined middleware chain [router + scope + procedure]
  :source_module   # The procedure module (MyApp.Procedures.Users)
]
```

### 2. `Zrpc.Router` DSL

**Module Attributes (accumulated during macro expansion):**
- `@zrpc_router_middleware` - Router-level middleware list
- `@zrpc_router_registrations` - List of `{module, namespace, scope_middleware}` tuples
- `@zrpc_router_scope_stack` - Stack for tracking nested scope state
- `@zrpc_router_aliases` - List of alias definitions

**Macros:**
- `use Zrpc.Router` - Setup module attributes, import macros, register `@before_compile`
- `middleware/1`, `middleware/2` - Add middleware (context-aware: router vs scope level)
- `procedures/2` - Register a procedure module at a namespace
- `scope/2` - Create a nested scope with prefix and optional middleware
- `alias/2` - Define a path alias

**Key Design: Scope Stack**

```elixir
defmacro scope(prefix, do: block) do
  quote do
    # Push scope onto stack
    current_stack = Module.get_attribute(__MODULE__, :zrpc_router_scope_stack) || []
    current_middleware = Module.get_attribute(__MODULE__, :zrpc_scope_middleware) || []

    Module.put_attribute(__MODULE__, :zrpc_router_scope_stack,
      [{unquote(prefix), current_middleware} | current_stack])
    Module.put_attribute(__MODULE__, :zrpc_scope_middleware, [])

    # Execute block (may contain middleware, procedures, nested scopes)
    unquote(block)

    # Pop scope from stack
    [_ | rest] = Module.get_attribute(__MODULE__, :zrpc_router_scope_stack)
    Module.put_attribute(__MODULE__, :zrpc_router_scope_stack, rest)

    # Restore parent scope middleware
    parent_middleware = case rest do
      [{_, mw} | _] -> mw
      [] -> []
    end
    Module.put_attribute(__MODULE__, :zrpc_scope_middleware, parent_middleware)
  end
end
```

### 3. `Zrpc.Router.Compiler`

**Compile-time validation:**
- No duplicate procedure paths
- All registered modules use `Zrpc.Procedure`
- All middleware modules implement `Zrpc.Middleware` behaviour
- Alias targets exist, no conflicts, no circular references

**Generated Functions:**

```elixir
@spec __zrpc_entries__() :: [Zrpc.Router.Entry.t()]
@spec __zrpc_entry__(String.t()) :: Zrpc.Router.Entry.t() | nil
@spec __zrpc_paths__() :: [String.t()]
@spec __zrpc_has_path__?(String.t()) :: boolean()
@spec __zrpc_procedure__(String.t()) :: Zrpc.Procedure.Definition.t() | nil
@spec __zrpc_modules__() :: [module()]
@spec __zrpc_middleware__(String.t()) :: [middleware_spec()]
@spec __zrpc_aliases__() :: map()
@spec __zrpc_alias__(String.t()) :: String.t() | nil
@spec __zrpc_resolve__(String.t()) :: Zrpc.Router.Entry.t() | nil
@spec __zrpc_queries__() :: [Zrpc.Router.Entry.t()]
@spec __zrpc_mutations__() :: [Zrpc.Router.Entry.t()]
@spec __zrpc_subscriptions__() :: [Zrpc.Router.Entry.t()]
@spec __zrpc_entries_by_prefix__(String.t()) :: [Zrpc.Router.Entry.t()]
```

---

## Implementation Steps

### Step 1: Create `Zrpc.Router.Entry` and `Zrpc.Router.Alias`
- Define Entry struct with typespec (path, path_segments, procedure, middleware, source_module)
- Define Alias struct with typespec (from, to, deprecated)
- Add helper functions for path manipulation and validation

### Step 2: Create `Zrpc.Router` DSL
- Implement `__using__/1` macro
- Implement `middleware/1` and `middleware/2` macros
- Implement `procedures/2` macro
- Implement `scope/2` macro with stack-based nesting
- Implement `alias/2` macro for path aliasing

### Step 3: Create `Zrpc.Router.Compiler`
- Implement `__before_compile__/1`
- Build entries from registrations (expand procedure modules)
- Validate no duplicate paths
- Generate introspection functions

### Step 4: Add Router Dispatch
- Add `Zrpc.Router.call/5` for path-based execution
- Add path validation and error handling
- Add similar path suggestions for not-found errors
- Add telemetry events for router operations

### Step 5: Add Batch Execution
- Add `Zrpc.Router.batch/4` for multiple procedure calls
- Implement parallel execution with Task.async_stream
- Add batch size validation
- Add batch telemetry events

### Step 6: Write Tests
- Test basic procedure registration
- Test nested scopes
- Test middleware inheritance and composition
- Test middleware skip option
- Test duplicate path detection
- Test introspection functions
- Test path-based execution (`call/5`)
- Test path aliases (creation, resolution, deprecated aliases)
- Test alias validation (target exists, no conflicts, no circular)
- Test error handling (not found, invalid path, suggestions)
- Test batch execution (`batch/4`)
- Test batch concurrency and timeout handling
- Test telemetry event emission

---

## Verification Plan

1. **Unit Tests**: Run `mix test test/zrpc/router_test.exs`
2. **All Tests**: Run `mix test` to ensure no regressions
3. **Static Analysis**: Run `mix credo --strict`
4. **Type Check**: Run `mix dialyzer`
5. **Manual Test**: Create a sample router in `iex -S mix` and verify introspection

---

## Edge Cases to Handle

**Router Structure:**
- Empty router (no procedures registered)
- Deeply nested scopes (3+ levels)
- Procedure module with no procedures defined
- Registering same module at multiple namespaces
- Scope with only middleware, no procedures
- Path conflicts across different scopes

**Aliases:**
- Alias to non-existent path (compile error)
- Alias conflicting with existing path (compile error)
- Circular aliases (compile error)
- Multiple aliases to same target (allowed)
- Deprecated alias telemetry/logging

**Middleware:**
- Empty middleware chain
- Middleware that modifies context significantly
- Middleware that short-circuits with error
- Skip middleware for specific procedures
- Duplicate middleware in chain (allowed, user responsibility)

**Error Handling:**
- Path with invalid characters
- Empty path string
- Path exceeding reasonable length (100+ chars)
- Unicode in path (reject)
- Case mismatch suggestions

**Batch Execution:**
- Empty batch (return empty list)
- Batch exceeding max size (error before execution)
- Single failed procedure in batch (others still execute)
- All procedures fail
- Timeout during batch execution
- Same procedure called multiple times in batch

---

## Implementation Checklist

- [ ] Create `lib/zrpc/router/entry.ex`
- [ ] Create `lib/zrpc/router/alias.ex`
- [ ] Create `lib/zrpc/router.ex`
- [ ] Create `lib/zrpc/router/compiler.ex`
- [ ] Add `Zrpc.Router.call/5`
- [ ] Add `Zrpc.Router.batch/4`
- [ ] Create `test/zrpc/router_test.exs`
- [ ] Run tests: `mix test`
- [ ] Run credo: `mix credo --strict`
- [ ] Run dialyzer: `mix dialyzer`

# Zrpc - tRPC-like RPC Framework for Elixir/Phoenix

## Overview

Build a schema-driven RPC library for Phoenix that provides:
- **tRPC-style DSL** for defining procedures (query/mutation/subscription) with Zoi schemas
- **Link-based transport abstraction**: HTTP, batched HTTP, Phoenix Channels (WebSocket)
- **Dual HTTP routing**: Single RPC endpoint + RESTful routes from same schema
- **Automatic code generation**: TypeScript clients (Zod v4) + OpenAPI 3.1 specs
- **Integrated middleware**: RPC-specific middleware that works with Phoenix Plugs

---

## Transport Layer: Links

Links provide transport abstraction - the client doesn't care if it's HTTP or WebSocket.

### Link Types

| Link | Transport | Use Case |
|------|-----------|----------|
| `httpLink` | HTTP POST/GET | Simple single requests |
| `httpBatchLink` | HTTP POST | Batches multiple calls (1ms debounce) |
| `channelLink` | Phoenix Channel | WebSocket for subscriptions + queries/mutations |
| `splitLink` | Conditional | Route by operation type |

### Server-Side Transport Handlers

```elixir
# HTTP transport (Plug)
forward "/rpc", Zrpc.Plug.RpcHandler, router: MyAppWeb.RpcRouter

# WebSocket transport (Phoenix Channel)
channel "zrpc:*", Zrpc.Channel.RpcChannel, router: MyAppWeb.RpcRouter
```

### Phoenix Channel Handler

```elixir
defmodule Zrpc.Channel.RpcChannel do
  use Phoenix.Channel

  def join("zrpc:main", _params, socket) do
    {:ok, socket}
  end

  # Handle RPC calls over WebSocket
  def handle_in("rpc", %{"path" => path, "input" => input}, socket) do
    case Zrpc.execute(socket.assigns.router, path, input, build_ctx(socket)) do
      {:ok, result} -> {:reply, {:ok, %{result: result}}, socket}
      {:error, error} -> {:reply, {:error, error}, socket}
    end
  end

  # Handle subscriptions
  def handle_in("subscribe", %{"path" => path, "input" => input}, socket) do
    # Start subscription, push events to client
    {:ok, subscription_id} = Zrpc.subscribe(path, input, socket)
    {:reply, {:ok, %{subscription_id: subscription_id}}, socket}
  end
end
```

### Subscription Procedure (Server)

```elixir
defmodule MyApp.Procedures.Messages do
  use Zrpc.Procedure

  subscription :on_new_message do
    input Zoi.object(%{
      room_id: Zoi.string()
    })

    output Zoi.object(%{
      id: Zoi.string(),
      content: Zoi.string(),
      user_id: Zoi.string()
    })

    # Returns a stream/observable
    handler fn %{room_id: room_id}, ctx ->
      # Subscribe to Phoenix PubSub
      Phoenix.PubSub.subscribe(MyApp.PubSub, "room:#{room_id}")

      # Return stream that yields messages
      Stream.resource(
        fn -> :ok end,
        fn state ->
          receive do
            {:new_message, msg} -> {[msg], state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end
end
```

---

## TypeScript Client with Links

### Link Configuration

```typescript
import {
  createZrpcClient,
  httpLink,
  httpBatchLink,
  channelLink,
  splitLink,
  loggerLink
} from '@zrpc/client';

// Simple HTTP client
const client = createZrpcClient({
  links: [
    httpLink({ url: 'http://localhost:4000/api/rpc' })
  ]
});

// Batched HTTP (recommended for queries/mutations)
const batchedClient = createZrpcClient({
  links: [
    loggerLink(),  // Logs all operations
    httpBatchLink({
      url: 'http://localhost:4000/api/rpc',
      maxBatchSize: 10,
      batchInterval: 10  // ms
    })
  ]
});

// Phoenix Channel for real-time
const wsClient = createZrpcClient({
  links: [
    channelLink({
      socket: new PhoenixSocket('ws://localhost:4000/socket'),
      topic: 'zrpc:main'
    })
  ]
});

// Split: HTTP for queries/mutations, WebSocket for subscriptions
const hybridClient = createZrpcClient({
  links: [
    loggerLink(),
    splitLink({
      condition: (op) => op.type === 'subscription',
      true: channelLink({
        socket: phoenixSocket,
        topic: 'zrpc:main'
      }),
      false: httpBatchLink({
        url: 'http://localhost:4000/api/rpc'
      })
    })
  ]
});
```

### Link Interface (TypeScript)

```typescript
// Link is a function that takes runtime and returns operation handler
type ZrpcLink = (runtime: ZrpcRuntime) => LinkHandler;

type LinkHandler = (opts: {
  op: Operation;
  next: (op: Operation) => Observable<Result>;
}) => Observable<Result>;

type Operation = {
  id: string;
  type: 'query' | 'mutation' | 'subscription';
  path: string;      // e.g., "users.getUser"
  input: unknown;
  context: Record<string, unknown>;  // Mutable, shared across chain
};

// Custom link example
const authLink: ZrpcLink = () => ({ op, next }) => {
  // Add auth header to context
  op.context.headers = {
    ...op.context.headers,
    'Authorization': `Bearer ${getToken()}`
  };
  return next(op);
};
```

### Client Usage with Subscriptions

```typescript
const client = createZrpcClient({ links: [...] });

// Query
const user = await client.users.getUser.query({ id: '123' });

// Mutation
const newUser = await client.users.createUser.mutate({
  name: 'John',
  email: 'john@example.com'
});

// Subscription (returns unsubscribe function)
const unsubscribe = client.messages.onNewMessage.subscribe(
  { roomId: 'room-123' },
  {
    onData: (message) => console.log('New message:', message),
    onError: (error) => console.error('Error:', error),
    onComplete: () => console.log('Subscription ended')
  }
);

// Later: cleanup
unsubscribe();
```

---

## Error Handling

### Error Types (Elixir)

```elixir
defmodule Zrpc.Error do
  @type code ::
    :bad_request          # 400 - Malformed request
    | :unauthorized       # 401 - Not authenticated
    | :forbidden          # 403 - Not authorized
    | :not_found          # 404 - Resource not found
    | :conflict           # 409 - Resource conflict
    | :validation_error   # 422 - Input validation failed
    | :too_many_requests  # 429 - Rate limited
    | :internal_error     # 500 - Server error

  @type t :: %__MODULE__{
    code: code(),
    message: String.t(),
    details: map() | nil,       # Additional context
    path: [String.t()] | nil,   # For validation errors: field path
    cause: Exception.t() | nil  # Original exception (not sent to client)
  }

  defstruct [:code, :message, :details, :path, :cause]

  # Convenience constructors
  def not_found(message \\ "Not found"), do: %__MODULE__{code: :not_found, message: message}
  def unauthorized(message \\ "Unauthorized"), do: %__MODULE__{code: :unauthorized, message: message}
  def forbidden(message \\ "Forbidden"), do: %__MODULE__{code: :forbidden, message: message}
  def validation_error(errors), do: %__MODULE__{code: :validation_error, message: "Validation failed", details: errors}
end
```

### Handler Return Values

```elixir
# Success
{:ok, data}

# Simple error
{:error, :not_found}
{:error, :unauthorized, "Invalid token"}

# Structured error
{:error, %Zrpc.Error{code: :conflict, message: "Email already exists"}}

# Validation errors from Zoi are automatically converted
```

### JSON Response Format (JSON-RPC 2.0 inspired)

```json
// Success
{
  "result": {
    "data": { "id": "123", "name": "John" }
  }
}

// Error
{
  "error": {
    "code": "NOT_FOUND",
    "message": "User not found",
    "details": null,
    "path": null
  }
}

// Validation Error
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Validation failed",
    "details": {
      "email": ["must be a valid email"],
      "name": ["must be at least 2 characters"]
    },
    "path": null
  }
}

// Batched Response (HTTP 207 Multi-Status)
[
  { "result": { "data": { "id": "1" } } },
  { "error": { "code": "NOT_FOUND", "message": "User not found" } },
  { "result": { "data": { "id": "3" } } }
]
```

### Error Propagation Through Links (TypeScript)

```typescript
// ZrpcError class
class ZrpcError extends Error {
  code: string;      // "NOT_FOUND", "UNAUTHORIZED", etc.
  details?: unknown;
  path?: string[];

  // Check error type
  isNotFound(): boolean { return this.code === 'NOT_FOUND'; }
  isUnauthorized(): boolean { return this.code === 'UNAUTHORIZED'; }
  isValidationError(): boolean { return this.code === 'VALIDATION_ERROR'; }
}

// Usage in client
try {
  const user = await client.users.getUser.query({ id: '123' });
} catch (error) {
  if (error instanceof ZrpcError) {
    if (error.isNotFound()) {
      showNotFoundPage();
    } else if (error.isValidationError()) {
      setFormErrors(error.details);
    } else if (error.isUnauthorized()) {
      redirectToLogin();
    }
  }
}

// Links can intercept and transform errors
const retryLink: ZrpcLink = () => ({ op, next }) => {
  return new Observable((observer) => {
    let retries = 0;
    const maxRetries = 3;

    const execute = () => {
      next(op).subscribe({
        next: (value) => observer.next(value),
        error: (error) => {
          if (error.code === 'TOO_MANY_REQUESTS' && retries < maxRetries) {
            retries++;
            setTimeout(execute, 1000 * retries);
          } else {
            observer.error(error);
          }
        },
        complete: () => observer.complete(),
      });
    };

    execute();
  });
};
```

---

## Request Batching

### Client-Side Batching (httpBatchLink)

```typescript
const client = createZrpcClient({
  links: [
    httpBatchLink({
      url: 'http://localhost:4000/api/rpc',
      maxBatchSize: 10,      // Max operations per batch
      batchInterval: 10,      // Wait 10ms before sending batch
    })
  ]
});

// These 3 calls made simultaneously are batched into 1 HTTP request
const [user, posts, comments] = await Promise.all([
  client.users.getUser.query({ id: '1' }),
  client.posts.list.query({ userId: '1' }),
  client.comments.list.query({ postId: '5' })
]);
```

### Batching Implementation (TypeScript)

```typescript
function httpBatchLink(opts: BatchLinkOptions): ZrpcLink {
  return () => {
    let pendingBatch: PendingOperation[] = [];
    let batchTimer: NodeJS.Timeout | null = null;

    const flush = async () => {
      const batch = pendingBatch;
      pendingBatch = [];
      batchTimer = null;

      // Build batch request
      const operations = batch.map((op, index) => ({
        id: index,
        path: op.operation.path,
        input: op.operation.input,
        type: op.operation.type
      }));

      try {
        const response = await fetch(`${opts.url}?batch=1`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(operations)
        });

        const results = await response.json();

        // Resolve each operation with its result
        batch.forEach((pending, index) => {
          const result = results[index];
          if (result.error) {
            pending.reject(new ZrpcError(result.error));
          } else {
            pending.resolve(result.result);
          }
        });
      } catch (error) {
        batch.forEach(pending => pending.reject(error));
      }
    };

    return ({ op, next }) => {
      return new Observable((observer) => {
        const pending = {
          operation: op,
          resolve: (value) => observer.next(value),
          reject: (error) => observer.error(error)
        };

        pendingBatch.push(pending);

        // Start or reset timer
        if (!batchTimer) {
          batchTimer = setTimeout(flush, opts.batchInterval);
        }

        // Flush if batch is full
        if (pendingBatch.length >= opts.maxBatchSize) {
          clearTimeout(batchTimer);
          flush();
        }
      });
    };
  };
}
```

### Server-Side Batch Handler (Elixir)

```elixir
defmodule Zrpc.Plug.BatchHandler do
  import Plug.Conn

  def call(conn, opts) do
    router = opts[:router]

    with {:ok, body, conn} <- read_body(conn),
         {:ok, operations} <- Jason.decode(body) do

      # Execute all operations concurrently
      results =
        operations
        |> Enum.map(fn %{"id" => id, "path" => path, "input" => input} ->
          Task.async(fn ->
            {id, execute_operation(router, path, input, conn)}
          end)
        end)
        |> Task.await_many(30_000)
        |> Enum.sort_by(fn {id, _result} -> id end)
        |> Enum.map(fn {_id, result} -> result end)

      # Determine status code
      status = if Enum.any?(results, &match?(%{error: _}, &1)), do: 207, else: 200

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(results))
    end
  end

  defp execute_operation(router, path, input, conn) do
    ctx = Zrpc.Context.from_conn(conn)

    case Zrpc.execute(router, path, input, ctx) do
      {:ok, data} -> %{result: %{data: data}}
      {:error, error} -> %{error: Zrpc.Error.to_json(error)}
    end
  end
end
```

### Batch Request Format

```
POST /api/rpc?batch=1
Content-Type: application/json

[
  { "id": 0, "path": "users.getUser", "input": { "id": "1" }, "type": "query" },
  { "id": 1, "path": "posts.list", "input": { "userId": "1" }, "type": "query" },
  { "id": 2, "path": "comments.list", "input": { "postId": "5" }, "type": "query" }
]

Response (207 Multi-Status if mixed success/error):
[
  { "result": { "data": { "id": "1", "name": "John" } } },
  { "result": { "data": [{ "id": "p1", "title": "Post 1" }] } },
  { "result": { "data": [{ "id": "c1", "text": "Comment" }] } }
]
```

---

## Authentication Patterns

### HTTP Transport: Token-Based Auth

```elixir
# Middleware for HTTP
defmodule MyAppWeb.Middleware.RequireAuth do
  @behaviour Zrpc.Middleware

  def init(opts), do: opts

  def call(ctx, _opts, next) do
    case extract_token(ctx) do
      {:ok, token} ->
        case verify_token(token) do
          {:ok, user} ->
            ctx = Zrpc.Context.assign(ctx, :current_user, user)
            next.(ctx)
          {:error, _reason} ->
            {:error, :unauthorized, "Invalid or expired token"}
        end
      :error ->
        {:error, :unauthorized, "Missing authorization header"}
    end
  end

  defp extract_token(%{conn: conn}) do
    # HTTP: Extract from Authorization header
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> :error
    end
  end

  defp extract_token(%{socket: socket}) do
    # WebSocket: Extract from socket assigns (set during join)
    case socket.assigns[:token] do
      nil -> :error
      token -> {:ok, token}
    end
  end
end
```

### WebSocket Transport: Auth on Join

```elixir
defmodule Zrpc.Channel.RpcChannel do
  use Phoenix.Channel

  # Authenticate during channel join
  def join("zrpc:main", %{"token" => token}, socket) do
    case verify_token(token) do
      {:ok, user} ->
        socket = assign(socket, :current_user, user)
        socket = assign(socket, :token, token)
        {:ok, socket}
      {:error, _reason} ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  def join("zrpc:main", _params, _socket) do
    {:error, %{reason: "missing_token"}}
  end

  # User is already authenticated for all subsequent messages
  def handle_in("rpc", payload, socket) do
    ctx = Zrpc.Context.from_socket(socket)
    # ctx.assigns.current_user is available
    # ...
  end
end
```

### TypeScript Client: Auth Link

```typescript
// Auth link adds token to all requests
const authLink: ZrpcLink = () => ({ op, next }) => {
  const token = getAuthToken(); // From localStorage, cookie, etc.

  if (token) {
    op.context.headers = {
      ...op.context.headers,
      'Authorization': `Bearer ${token}`
    };
  }

  return next(op);
};

// Token refresh link (intercepts 401 errors)
const tokenRefreshLink: ZrpcLink = () => ({ op, next }) => {
  return new Observable((observer) => {
    next(op).subscribe({
      next: (value) => observer.next(value),
      error: async (error) => {
        if (error.code === 'UNAUTHORIZED' && !op.context.isRetry) {
          try {
            await refreshToken();  // Refresh the token
            op.context.isRetry = true;
            op.context.headers = {
              ...op.context.headers,
              'Authorization': `Bearer ${getAuthToken()}`
            };
            // Retry the operation
            next(op).subscribe(observer);
          } catch (refreshError) {
            // Token refresh failed, redirect to login
            redirectToLogin();
            observer.error(error);
          }
        } else {
          observer.error(error);
        }
      },
      complete: () => observer.complete()
    });
  });
};

// Full client setup with auth
const client = createZrpcClient({
  links: [
    loggerLink(),
    tokenRefreshLink,  // Handle token refresh
    authLink,          // Add auth headers
    splitLink({
      condition: (op) => op.type === 'subscription',
      true: channelLink({
        socket: phoenixSocket,
        topic: 'zrpc:main',
        params: () => ({ token: getAuthToken() })  // Pass token on join
      }),
      false: httpBatchLink({ url: '/api/rpc' })
    })
  ]
});
```

### Phoenix Channel Auth with Token Refresh

```typescript
// channelLink with auth
function channelLink(opts: ChannelLinkOptions): ZrpcLink {
  let channel: Channel | null = null;

  const getChannel = () => {
    if (!channel) {
      const socket = opts.socket;
      // Pass token during channel join
      channel = socket.channel(opts.topic, opts.params?.() ?? {});

      channel.onError((error) => {
        if (error.reason === 'unauthorized') {
          // Token expired, refresh and rejoin
          refreshToken().then(() => {
            channel?.leave();
            channel = null;
            getChannel(); // Rejoin with new token
          });
        }
      });

      channel.join();
    }
    return channel;
  };

  return () => ({ op, next }) => {
    // ... use getChannel() for operations
  };
}
```

### Context Structure (Transport-Agnostic)

```elixir
defmodule Zrpc.Context do
  @type transport :: :http | :websocket

  @type t :: %__MODULE__{
    transport: transport(),
    conn: Plug.Conn.t() | nil,        # Only for HTTP
    socket: Phoenix.Socket.t() | nil,  # Only for WebSocket
    assigns: map(),
    metadata: map()
  }

  def from_conn(conn) do
    %__MODULE__{
      transport: :http,
      conn: conn,
      socket: nil,
      assigns: %{},
      metadata: %{request_id: get_request_id(conn)}
    }
  end

  def from_socket(socket) do
    %__MODULE__{
      transport: :websocket,
      conn: nil,
      socket: socket,
      assigns: Map.take(socket.assigns, [:current_user]),
      metadata: %{socket_id: socket.id}
    }
  end
end
```

---

## API Design

### Procedure Definition (tRPC-style)

```elixir
defmodule MyApp.Procedures.Users do
  use Zrpc.Procedure

  query :get_user do
    meta do
      description "Get user by ID"
      tags ["users"]
    end

    input Zoi.object(%{
      id: Zoi.string() |> Zoi.uuid()
    })

    output Zoi.object(%{
      id: Zoi.string(),
      name: Zoi.string(),
      email: Zoi.email()
    })

    route method: :get, path: "/users/{id}"  # Optional REST mapping

    handler fn input, ctx ->
      MyApp.Users.get_user(input.id)
    end
  end

  mutation :create_user do
    input Zoi.object(%{
      name: Zoi.string() |> Zoi.min(1),
      email: Zoi.email()
    })

    handler fn input, ctx ->
      MyApp.Users.create_user(input, ctx.assigns.current_user)
    end
  end
end
```

### Router with Middleware

```elixir
defmodule MyAppWeb.RpcRouter do
  use Zrpc.Router

  middleware Zrpc.Middleware.Logger

  router :auth, MyApp.Procedures.Auth

  scope do
    middleware MyAppWeb.Middleware.RequireAuth
    router :users, MyApp.Procedures.Users
    router :posts, MyApp.Procedures.Posts
  end
end
```

### Phoenix Integration

```elixir
# router.ex
scope "/api" do
  forward "/rpc", Zrpc.Plug.RpcHandler, router: MyAppWeb.RpcRouter
  forward "/v1", Zrpc.Plug.RestHandler, router: MyAppWeb.RpcRouter
end

get "/openapi.json", Zrpc.Plug.OpenApiHandler, router: MyAppWeb.RpcRouter
```

---

## Module Structure

```
lib/zrpc/
  # Core
  procedure.ex              # Procedure DSL (query/mutation/subscription macros)
  procedure/
    definition.ex           # Procedure struct
    compiler.ex             # Compile-time procedure processing
    executor.ex             # Runtime execution with middleware

  router.ex                 # Router DSL
  router/
    definition.ex           # Router struct
    compiler.ex             # Compile-time router tree
    resolver.ex             # Resolve procedure by path

  context.ex                # Request context (conn/socket, assigns, metadata)
  error.ex                  # Error types and HTTP status mapping

  # Middleware
  middleware.ex             # Behaviour definition
  middleware/
    logger.ex               # Request logging
    telemetry.ex            # Telemetry events

  # Transport: HTTP (Plug)
  plug/
    rpc_handler.ex          # POST /rpc/users.get_user
    batch_handler.ex        # POST /rpc?batch=1 (batched requests)
    rest_handler.ex         # GET /v1/users/:id
    openapi_handler.ex      # Serve OpenAPI spec

  # Transport: WebSocket (Phoenix Channel)
  channel/
    rpc_channel.ex          # Phoenix Channel for RPC calls
    subscription.ex         # Subscription state management

  # Schema Processing
  schema/
    json_schema.ex          # Zoi -> JSON Schema
    openapi.ex              # Generate OpenAPI 3.1 spec

  # Code Generation (Elixir-side)
  generator/
    typescript.ex           # Generate TS client structure
    zod.ex                  # Generate Zod schemas from Zoi
    links.ex                # Generate link implementations
    templates/
      index.ts.eex          # Main export file
      schemas.ts.eex        # Zod schemas
      client.ts.eex         # Client with procedure proxies
      links/
        http_link.ts.eex
        http_batch_link.ts.eex
        channel_link.ts.eex
        split_link.ts.eex
        logger_link.ts.eex

  # Dev Tools
  watcher/
    server.ex               # File watcher GenServer

  config.ex                 # Configuration

lib/mix/tasks/
  zrpc.gen.client.ex        # mix zrpc.gen.client
  zrpc.gen.openapi.ex       # mix zrpc.gen.openapi
```

---

## Implementation Phases

### Phase 1: Core DSL
1. `Zrpc.Procedure` - macros for `query/2`, `mutation/2`, `subscription/2`
2. `Zrpc.Procedure.Definition` - struct with input/output/handler/meta
3. `Zrpc.Procedure.Compiler` - `@before_compile` hook to register procedures
4. `Zrpc.Context` - request context struct (transport-agnostic)

### Phase 2: Router
1. `Zrpc.Router` - macros for `router/2`, `middleware/1`, `scope/1`
2. `Zrpc.Router.Compiler` - build router tree at compile time
3. `Zrpc.Router.Resolver` - resolve "users.get_user" to procedure

### Phase 3: Middleware
1. `Zrpc.Middleware` behaviour - `init/1`, `call/3`
2. `Zrpc.Procedure.Executor` - chain middleware, execute handler
3. Built-in: Logger, Telemetry

### Phase 4: HTTP Transport (Plug)
1. `Zrpc.Plug.RpcHandler` - handle `POST /rpc/:path`
2. `Zrpc.Plug.BatchHandler` - handle batched requests `POST /rpc?batch=1`
3. Input parsing, Zoi validation, error formatting
4. JSON response serialization (JSON-RPC 2.0 style)

### Phase 5: WebSocket Transport (Channel)
1. `Zrpc.Channel.RpcChannel` - Phoenix Channel for RPC over WebSocket
2. `Zrpc.Channel.Subscription` - subscription lifecycle management
3. Integration with Phoenix.PubSub for subscriptions
4. Reconnection and state recovery handling

### Phase 6: Schema & OpenAPI
1. `Zrpc.Schema.JsonSchema` - convert Zoi to JSON Schema
2. `Zrpc.Schema.OpenApi` - generate OpenAPI 3.1 spec
3. `Zrpc.Plug.OpenApiHandler` - serve spec at runtime

### Phase 7: TypeScript Generation
1. `Zrpc.Generator.Zod` - JSON Schema -> Zod v4 code
2. `Zrpc.Generator.TypeScript` - generate client with procedure proxies
3. `Zrpc.Generator.Links` - generate link implementations:
   - `httpLink` - single HTTP requests
   - `httpBatchLink` - batched requests with debouncing
   - `channelLink` - Phoenix Channel transport
   - `splitLink` - conditional routing
   - `loggerLink` - debugging middleware
4. Mix tasks: `zrpc.gen.client`, `zrpc.gen.openapi`

### Phase 8: REST Handler
1. `Zrpc.Plug.RestHandler` - generate routes from `route/1` definitions
2. Path parameter extraction (`/users/{id}` -> `%{id: "123"}`)

### Phase 9: File Watcher
1. `Zrpc.Watcher.Server` - GenServer using `file_system`
2. Watch procedure/router modules, regenerate on change
3. Debounce rapid changes

---

## Configuration

```elixir
# config/config.exs
config :zrpc,
  typescript: [
    output_dir: "assets/js/generated",
    http_client: :axios,  # :axios | :fetch | :ky
    client_file: "client.ts",
    schemas_file: "schemas.ts"
  ],
  openapi: [
    output_file: "priv/static/openapi.json",
    info: [title: "My API", version: "1.0.0"]
  ],
  watcher: [
    enabled: Mix.env() == :dev,
    debounce_ms: 500
  ]
```

```json
// zrpc.config.json (optional, for frontend tooling)
{
  "typescript": {
    "outputDir": "./frontend/src/api",
    "httpClient": "axios",
    "baseUrl": "/api/rpc"
  }
}
```

---

## Generated TypeScript Client

```typescript
// Generated: client.ts
import { z } from "zod";

export const GetUserInputSchema = z.object({
  id: z.string().uuid(),
});

export const GetUserOutputSchema = z.object({
  id: z.string(),
  name: z.string(),
  email: z.string().email(),
});

export type GetUserInput = z.infer<typeof GetUserInputSchema>;
export type GetUserOutput = z.infer<typeof GetUserOutputSchema>;

export function createClient(config: { baseUrl: string }) {
  return {
    users: {
      getUser: async (input: GetUserInput): Promise<GetUserOutput> => {
        const validated = GetUserInputSchema.parse(input);
        const res = await axios.post(`${config.baseUrl}/users.get_user`, { input: validated });
        return GetUserOutputSchema.parse(res.data.result.data);
      },
    },
  };
}
```

---

## Key Files to Create

| File | Purpose |
|------|---------|
| `lib/zrpc/procedure.ex` | Core DSL macros (query/mutation/subscription) |
| `lib/zrpc/router.ex` | Router DSL macros |
| `lib/zrpc/context.ex` | Transport-agnostic request context |
| `lib/zrpc/middleware.ex` | Middleware behaviour |
| `lib/zrpc/plug/rpc_handler.ex` | HTTP RPC Plug |
| `lib/zrpc/plug/batch_handler.ex` | Batched HTTP requests |
| `lib/zrpc/channel/rpc_channel.ex` | Phoenix Channel transport |
| `lib/zrpc/channel/subscription.ex` | Subscription lifecycle |
| `lib/zrpc/schema/json_schema.ex` | Zoi -> JSON Schema |
| `lib/zrpc/generator/typescript.ex` | TS client generation |
| `lib/zrpc/generator/links.ex` | Link implementations |

---

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:zoi, "~> 0.15"},
    {:plug, "~> 1.14"},
    {:phoenix, "~> 1.7"},           # For Channel support
    {:phoenix_pubsub, "~> 2.1"},    # For subscriptions
    {:jason, "~> 1.4"},
    {:file_system, "~> 1.0", only: :dev}  # For file watcher
  ]
end
```

Note: Phoenix is optional - library works with just Plug for HTTP-only use cases.

---

## Verification

1. **Unit tests**: Test each module in isolation
   - Procedure compilation and registration
   - Router tree building
   - Middleware chaining
   - Schema conversion

2. **Integration tests**: Full request/response cycle
   - RPC handler with valid/invalid input
   - REST handler route matching
   - OpenAPI spec generation

3. **E2E verification**:
   - Create sample Phoenix app with Zrpc
   - Define procedures and router
   - Run `mix zrpc.gen.client`
   - Verify generated TypeScript compiles
   - Test client against running server

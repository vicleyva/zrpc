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
  - `middleware/1-2` - Procedure-level middleware

  ## Handler Styles

  ### Style A: Anonymous Function (inline)

      handler fn %{id: id}, ctx ->
        {:ok, get_user(id)}
      end

  ### Style B: Function Reference

      handler &MyApp.Handlers.Users.get_user/2

  ### Style C: Implicit (no handler directive)

  If no `handler` is specified, define a function with the procedure name:

      query :get_user do
        input Zoi.object(%{id: Zoi.string()})
      end

      def get_user(%{id: id}, ctx) do
        {:ok, MyApp.Users.get(id)}
      end
  """

  alias Zrpc.Procedure.{Definition, MetaParser}

  defmacro __using__(_opts) do
    quote do
      import Zrpc.Procedure,
        only: [
          query: 2,
          mutation: 2,
          subscription: 2,
          input: 1,
          output: 1,
          handler: 1,
          meta: 1,
          route: 1,
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

  ## Example

      query :get_user do
        input Zoi.object(%{id: Zoi.string()})
        output Zoi.object(%{id: Zoi.string(), name: Zoi.string()})

        handler fn %{id: id}, _ctx ->
          {:ok, %{id: id, name: "Test"}}
        end
      end
  """
  defmacro query(name, do: block) do
    define_procedure(:query, name, block, __CALLER__)
  end

  @doc """
  Defines a mutation procedure (write operation).

  Mutations are not idempotent and should use HTTP POST
  when exposed via REST routes.

  ## Example

      mutation :create_user do
        input Zoi.object(%{name: Zoi.string(), email: Zoi.email()})

        handler fn input, _ctx ->
          {:ok, %{id: "123", name: input.name, email: input.email}}
        end
      end
  """
  defmacro mutation(name, do: block) do
    define_procedure(:mutation, name, block, __CALLER__)
  end

  @doc """
  Defines a subscription procedure (real-time updates).

  Subscriptions are long-lived connections that push updates
  to clients. They require WebSocket transport.

  ## Example

      subscription :user_updated do
        input Zoi.object(%{user_id: Zoi.string()})

        handler fn %{user_id: user_id}, _ctx ->
          # Return stream or subscribe to PubSub
          {:ok, :subscribed}
        end
      end
  """
  defmacro subscription(name, do: block) do
    define_procedure(:subscription, name, block, __CALLER__)
  end

  # Private: Generate the procedure definition code
  defp define_procedure(type, name, block, caller) do
    source_base = %{file: caller.file, line: caller.line}

    quote do
      # Initialize temporary module attributes for this procedure
      Module.put_attribute(__MODULE__, :zrpc_current_input, nil)
      Module.put_attribute(__MODULE__, :zrpc_current_output, nil)
      Module.put_attribute(__MODULE__, :zrpc_current_handler_ast, nil)
      Module.put_attribute(__MODULE__, :zrpc_current_meta, %{})
      Module.put_attribute(__MODULE__, :zrpc_current_route, nil)
      Module.put_attribute(__MODULE__, :zrpc_current_middleware, [])

      # Execute the block (this will set the module attributes via directive macros)
      unquote(block)

      # Build the procedure definition (without handler for storage)
      # Store as {proc, handler_ast} tuple so Compiler can inject handler
      @zrpc_procedures {
        %Definition{
          name: unquote(name),
          type: unquote(type),
          input: Module.get_attribute(__MODULE__, :zrpc_current_input),
          output: Module.get_attribute(__MODULE__, :zrpc_current_output),
          handler: nil,
          meta: Module.get_attribute(__MODULE__, :zrpc_current_meta),
          route: Module.get_attribute(__MODULE__, :zrpc_current_route),
          middleware:
            Module.get_attribute(__MODULE__, :zrpc_current_middleware) |> Enum.reverse(),
          __source__: Map.put(unquote(Macro.escape(source_base)), :module, __MODULE__)
        },
        Module.get_attribute(__MODULE__, :zrpc_current_handler_ast)
      }

      # Clean up temporary attributes
      Module.delete_attribute(__MODULE__, :zrpc_current_input)
      Module.delete_attribute(__MODULE__, :zrpc_current_output)
      Module.delete_attribute(__MODULE__, :zrpc_current_handler_ast)
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
  - `{:error, %{...}}` - Structured error map

  ## Example

      handler fn %{id: id}, ctx ->
        case MyApp.Users.get_user(id) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end
      end
  """
  defmacro handler(func) do
    # Store the handler AST (quoted form) so it can be injected by the Compiler
    # We escape the AST so it's stored as data, not evaluated
    escaped_ast = Macro.escape(func)

    quote do
      Module.put_attribute(__MODULE__, :zrpc_current_handler_ast, unquote(escaped_ast))
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
      Module.put_attribute(
        __MODULE__,
        :zrpc_current_meta,
        Enum.into(unquote(keyword_list), %{})
      )
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
          {:ok, do_admin_action(input)}
        end
      end
  """
  defmacro middleware(module) do
    quote do
      current = Module.get_attribute(__MODULE__, :zrpc_current_middleware)
      Module.put_attribute(__MODULE__, :zrpc_current_middleware, [unquote(module) | current])
    end
  end

  defmacro middleware(module, opts) do
    quote do
      current = Module.get_attribute(__MODULE__, :zrpc_current_middleware)

      Module.put_attribute(
        __MODULE__,
        :zrpc_current_middleware,
        [{unquote(module), unquote(opts)} | current]
      )
    end
  end
end

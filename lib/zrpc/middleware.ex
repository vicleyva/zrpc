defmodule Zrpc.Middleware do
  @moduledoc """
  Behaviour for Zrpc middleware.

  Middleware can:
  - Modify the context before passing to the next middleware/handler
  - Short-circuit the chain by returning an error
  - Transform or wrap the response (via the continuation)

  ## Usage

      defmodule MyApp.Middleware.RequireAuth do
        use Zrpc.Middleware

        @impl true
        def call(ctx, _opts, next) do
          case extract_and_verify_token(ctx) do
            {:ok, user} ->
              ctx = Zrpc.Context.assign(ctx, :current_user, user)
              next.(ctx)
            {:error, reason} ->
              {:error, :unauthorized}
          end
        end
      end

  ## With Options

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
          case check_rate_limit(ctx, opts) do
            :ok -> next.(ctx)
            {:error, :rate_limited} -> {:error, :too_many_requests}
          end
        end
      end

  ## Execution Order

  Middleware executes in this order:

  1. Router-level middleware (defined in `Zrpc.Router`)
  2. Scope-level middleware (defined in router `scope do ... end`)
  3. Procedure-level middleware (defined inline in procedure)
  4. Handler execution

  ```
  Request -> Router MW -> Scope MW -> Procedure MW -> Handler
                                                        |
  Response <- Router MW <- Scope MW <- Procedure MW <- Result
  ```
  """

  @type opts :: term()
  @type next :: (Zrpc.Context.t() -> {:ok, Zrpc.Context.t()} | {:error, term()})

  @doc """
  Initialize middleware options at compile time.

  Called once when the middleware is registered. The return value
  is passed to `call/3` as the second argument.

  Default implementation returns the options unchanged.
  """
  @callback init(keyword()) :: opts()

  @doc """
  Execute the middleware.

  Receives:
  - `ctx` - The current context
  - `opts` - Options returned from `init/1`
  - `next` - Function to call the next middleware in chain

  Must return:
  - `{:ok, ctx}` - Success, modified context returned from next
  - `{:error, reason}` - Short-circuit with error
  """
  @callback call(Zrpc.Context.t(), opts(), next()) ::
              {:ok, Zrpc.Context.t()} | {:error, term()}

  @optional_callbacks [init: 1]

  defmacro __using__(_opts) do
    quote do
      @behaviour Zrpc.Middleware

      @doc false
      def init(opts), do: opts

      defoverridable init: 1
    end
  end
end

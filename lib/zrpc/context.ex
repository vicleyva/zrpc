defmodule Zrpc.Context do
  @moduledoc """
  Transport-agnostic request context that flows through the middleware chain.

  The context abstracts over the underlying transport (HTTP or WebSocket),
  allowing the same middleware and handlers to work with both.

  ## Fields

  - `transport` - `:http` or `:websocket`
  - `conn` - The Plug.Conn (HTTP only)
  - `socket` - The Phoenix.Socket (WebSocket only)
  - `assigns` - User-defined data (like current_user)
  - `metadata` - Request metadata (request_id, timing, etc.)
  - `procedure_path` - Full path like "users.get_user"
  - `procedure_type` - :query, :mutation, or :subscription

  ## Usage

      # Create from Plug.Conn (HTTP)
      ctx = Zrpc.Context.from_conn(conn)

      # Create from Phoenix.Socket (WebSocket)
      ctx = Zrpc.Context.from_socket(socket)

      # Create for testing
      ctx = Zrpc.Context.new(assigns: %{current_user: user})

      # Assign values
      ctx = Zrpc.Context.assign(ctx, :current_user, user)
      ctx = Zrpc.Context.assign(ctx, current_user: user, role: :admin)

      # Get values
      user = Zrpc.Context.get_assign(ctx, :current_user)
  """

  @type transport :: :http | :websocket

  @type t :: %__MODULE__{
          transport: transport(),
          conn: term() | nil,
          socket: term() | nil,
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

  ## Options

  - `:path` - The procedure path (e.g., "users.get_user")
  - `:type` - The procedure type (:query, :mutation, :subscription)

  ## Example

      ctx = Zrpc.Context.from_conn(conn, path: "users.get_user", type: :query)
  """
  @spec from_conn(term(), keyword()) :: t()
  def from_conn(conn, opts \\ []) do
    %__MODULE__{
      transport: :http,
      conn: conn,
      socket: nil,
      assigns: %{},
      metadata: %{
        request_id: get_request_id(conn),
        started_at: System.monotonic_time(:microsecond),
        remote_ip: format_remote_ip(conn)
      },
      procedure_path: opts[:path],
      procedure_type: opts[:type]
    }
  end

  @doc """
  Creates a context from a Phoenix.Socket (WebSocket transport).

  ## Options

  - `:path` - The procedure path (e.g., "users.get_user")
  - `:type` - The procedure type (:query, :mutation, :subscription)

  ## Example

      ctx = Zrpc.Context.from_socket(socket, path: "messages.subscribe", type: :subscription)
  """
  @spec from_socket(term(), keyword()) :: t()
  def from_socket(socket, opts \\ []) do
    %__MODULE__{
      transport: :websocket,
      conn: nil,
      socket: socket,
      assigns: extract_socket_assigns(socket),
      metadata: %{
        socket_id: get_socket_id(socket),
        started_at: System.monotonic_time(:microsecond),
        channel_topic: get_socket_topic(socket)
      },
      procedure_path: opts[:path],
      procedure_type: opts[:type]
    }
  end

  @doc """
  Creates an empty context (useful for testing).

  ## Options

  - `:transport` - The transport type (default: `:http`)
  - `:assigns` - Initial assigns map
  - `:metadata` - Initial metadata map
  - `:path` - The procedure path
  - `:type` - The procedure type

  ## Example

      ctx = Zrpc.Context.new()
      ctx = Zrpc.Context.new(transport: :websocket, assigns: %{user_id: "123"})
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      transport: Keyword.get(opts, :transport, :http),
      conn: nil,
      socket: nil,
      assigns: Keyword.get(opts, :assigns, %{}),
      metadata:
        Map.merge(
          %{started_at: System.monotonic_time(:microsecond)},
          Keyword.get(opts, :metadata, %{})
        ),
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

  ## Example

      user = Zrpc.Context.get_assign(ctx, :current_user)
      role = Zrpc.Context.get_assign(ctx, :role, :guest)
  """
  @spec get_assign(t(), atom(), term()) :: term()
  def get_assign(%__MODULE__{assigns: assigns}, key, default \\ nil) do
    Map.get(assigns, key, default)
  end

  @doc """
  Adds metadata to the context.

  ## Example

      ctx = Zrpc.Context.put_metadata(ctx, :trace_id, trace_id)
  """
  @spec put_metadata(t(), atom(), term()) :: t()
  def put_metadata(%__MODULE__{} = ctx, key, value) when is_atom(key) do
    %{ctx | metadata: Map.put(ctx.metadata, key, value)}
  end

  @doc """
  Gets metadata from the context.

  ## Example

      request_id = Zrpc.Context.get_metadata(ctx, :request_id)
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

  @doc """
  Updates the procedure path and type.
  """
  @spec with_procedure(t(), String.t(), :query | :mutation | :subscription) :: t()
  def with_procedure(%__MODULE__{} = ctx, path, type)
      when is_binary(path) and type in [:query, :mutation, :subscription] do
    %{ctx | procedure_path: path, procedure_type: type}
  end

  # Private helpers

  defp get_request_id(conn) do
    case get_conn_header(conn, "x-request-id") do
      nil -> generate_request_id()
      id -> id
    end
  end

  defp get_conn_header(conn, header) do
    # Handle Plug.Conn structure
    case Map.get(conn, :req_headers) do
      headers when is_list(headers) ->
        Enum.find_value(headers, fn
          {^header, value} -> value
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp format_remote_ip(conn) do
    case Map.get(conn, :remote_ip) do
      ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
      other -> inspect(other)
    end
  end

  defp get_socket_id(socket) do
    Map.get(socket, :id, nil)
  end

  defp get_socket_topic(socket) do
    Map.get(socket, :topic, nil)
  end

  defp extract_socket_assigns(socket) do
    case Map.get(socket, :assigns) do
      assigns when is_map(assigns) ->
        assigns
        |> Map.take([:current_user, :user_id, :token, :locale])
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()

      _ ->
        %{}
    end
  end
end

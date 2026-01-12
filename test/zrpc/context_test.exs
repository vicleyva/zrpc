defmodule Zrpc.ContextTest do
  use ExUnit.Case, async: true

  alias Zrpc.Context

  describe "new/1" do
    test "creates empty context with defaults" do
      ctx = Context.new()
      assert ctx.transport == :http
      assert ctx.assigns == %{}
      assert ctx.conn == nil
      assert ctx.socket == nil
      assert ctx.procedure_path == nil
      assert ctx.procedure_type == nil
    end

    test "accepts transport option" do
      ctx = Context.new(transport: :websocket)
      assert ctx.transport == :websocket
    end

    test "accepts assigns option" do
      ctx = Context.new(assigns: %{user_id: "123"})
      assert ctx.assigns == %{user_id: "123"}
    end

    test "accepts metadata option" do
      ctx = Context.new(metadata: %{trace_id: "abc"})
      assert ctx.metadata.trace_id == "abc"
      assert Map.has_key?(ctx.metadata, :started_at)
    end

    test "accepts path and type options" do
      ctx = Context.new(path: "users.get_user", type: :query)
      assert ctx.procedure_path == "users.get_user"
      assert ctx.procedure_type == :query
    end
  end

  describe "from_conn/2" do
    test "creates HTTP context from conn-like map" do
      conn = %{
        req_headers: [{"x-request-id", "test-req-id"}],
        remote_ip: {127, 0, 0, 1}
      }

      ctx = Context.from_conn(conn)
      assert ctx.transport == :http
      assert ctx.conn == conn
      assert ctx.socket == nil
      assert ctx.metadata.request_id == "test-req-id"
      assert ctx.metadata.remote_ip == "127.0.0.1"
    end

    test "generates request_id when not provided" do
      conn = %{req_headers: [], remote_ip: {127, 0, 0, 1}}
      ctx = Context.from_conn(conn)
      assert is_binary(ctx.metadata.request_id)
      assert String.length(ctx.metadata.request_id) == 32
    end

    test "accepts path and type options" do
      conn = %{req_headers: [], remote_ip: {127, 0, 0, 1}}
      ctx = Context.from_conn(conn, path: "users.list", type: :query)
      assert ctx.procedure_path == "users.list"
      assert ctx.procedure_type == :query
    end
  end

  describe "from_socket/2" do
    test "creates WebSocket context from socket-like map" do
      socket = %{
        id: "socket-123",
        topic: "zrpc:main",
        assigns: %{current_user: %{id: "user-1"}}
      }

      ctx = Context.from_socket(socket)
      assert ctx.transport == :websocket
      assert ctx.socket == socket
      assert ctx.conn == nil
      assert ctx.metadata.socket_id == "socket-123"
      assert ctx.metadata.channel_topic == "zrpc:main"
      assert ctx.assigns.current_user == %{id: "user-1"}
    end

    test "accepts path and type options" do
      socket = %{id: "socket-123", assigns: %{}}
      ctx = Context.from_socket(socket, path: "messages.subscribe", type: :subscription)
      assert ctx.procedure_path == "messages.subscribe"
      assert ctx.procedure_type == :subscription
    end
  end

  describe "assign/3" do
    test "assigns a single key-value pair" do
      ctx = Context.new() |> Context.assign(:user_id, 123)
      assert Context.get_assign(ctx, :user_id) == 123
    end

    test "overwrites existing value" do
      ctx =
        Context.new()
        |> Context.assign(:role, :user)
        |> Context.assign(:role, :admin)

      assert Context.get_assign(ctx, :role) == :admin
    end
  end

  describe "assign/2 with keyword list" do
    test "assigns multiple key-value pairs" do
      ctx = Context.new() |> Context.assign(user_id: 123, role: :admin)
      assert Context.get_assign(ctx, :user_id) == 123
      assert Context.get_assign(ctx, :role) == :admin
    end

    test "merges with existing assigns" do
      ctx =
        Context.new(assigns: %{existing: "value"})
        |> Context.assign(new_key: "new_value")

      assert Context.get_assign(ctx, :existing) == "value"
      assert Context.get_assign(ctx, :new_key) == "new_value"
    end
  end

  describe "get_assign/3" do
    test "returns value when key exists" do
      ctx = Context.new(assigns: %{key: "value"})
      assert Context.get_assign(ctx, :key) == "value"
    end

    test "returns nil when key does not exist" do
      ctx = Context.new()
      assert Context.get_assign(ctx, :missing) == nil
    end

    test "returns default when key does not exist" do
      ctx = Context.new()
      assert Context.get_assign(ctx, :missing, "default") == "default"
    end
  end

  describe "put_metadata/3" do
    test "adds metadata" do
      ctx = Context.new() |> Context.put_metadata(:trace_id, "abc123")
      assert Context.get_metadata(ctx, :trace_id) == "abc123"
    end
  end

  describe "get_metadata/3" do
    test "returns value when key exists" do
      ctx = Context.new(metadata: %{key: "value"})
      assert Context.get_metadata(ctx, :key) == "value"
    end

    test "returns default when key does not exist" do
      ctx = Context.new()
      assert Context.get_metadata(ctx, :missing, "default") == "default"
    end
  end

  describe "elapsed_us/1 and elapsed_ms/1" do
    test "returns elapsed time" do
      ctx = Context.new()
      Process.sleep(10)
      elapsed = Context.elapsed_us(ctx)
      assert elapsed >= 10_000
    end

    test "elapsed_ms returns milliseconds" do
      ctx = Context.new()
      Process.sleep(15)
      elapsed = Context.elapsed_ms(ctx)
      assert elapsed >= 15.0
    end

    test "returns 0 when started_at is missing" do
      ctx = %Context{transport: :http, metadata: %{}}
      assert Context.elapsed_us(ctx) == 0
    end
  end

  describe "transport checks" do
    test "http?/1 returns true for HTTP context" do
      assert Context.http?(Context.new(transport: :http))
      refute Context.http?(Context.new(transport: :websocket))
    end

    test "websocket?/1 returns true for WebSocket context" do
      assert Context.websocket?(Context.new(transport: :websocket))
      refute Context.websocket?(Context.new(transport: :http))
    end
  end

  describe "with_procedure/3" do
    test "sets procedure path and type" do
      ctx =
        Context.new()
        |> Context.with_procedure("users.get_user", :query)

      assert ctx.procedure_path == "users.get_user"
      assert ctx.procedure_type == :query
    end
  end
end

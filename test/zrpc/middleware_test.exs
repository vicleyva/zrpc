defmodule Zrpc.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Zrpc.Context

  describe "use Zrpc.Middleware" do
    defmodule SimpleMiddleware do
      use Zrpc.Middleware

      @impl true
      def call(ctx, _opts, next) do
        ctx = Context.assign(ctx, :simple_ran, true)
        next.(ctx)
      end
    end

    defmodule CustomInitMiddleware do
      use Zrpc.Middleware

      @impl true
      def init(opts) do
        %{
          prefix: Keyword.get(opts, :prefix, "default")
        }
      end

      @impl true
      def call(ctx, opts, next) do
        ctx = Context.assign(ctx, :prefix, opts.prefix)
        next.(ctx)
      end
    end

    defmodule ShortCircuitMiddleware do
      use Zrpc.Middleware

      @impl true
      def call(_ctx, _opts, _next) do
        {:error, :unauthorized}
      end
    end

    test "provides default init/1 implementation" do
      opts = [key: "value"]
      assert SimpleMiddleware.init(opts) == opts
    end

    test "allows custom init/1 override" do
      opts = [prefix: "custom"]
      assert CustomInitMiddleware.init(opts) == %{prefix: "custom"}
    end

    test "middleware can modify context and continue" do
      ctx = Context.new()

      {:ok, result_ctx} =
        SimpleMiddleware.call(ctx, [], fn ctx ->
          {:ok, ctx}
        end)

      assert Context.get_assign(result_ctx, :simple_ran) == true
    end

    test "middleware can short-circuit the chain" do
      ctx = Context.new()

      result =
        ShortCircuitMiddleware.call(ctx, [], fn _ctx ->
          {:ok, ctx}
        end)

      assert result == {:error, :unauthorized}
    end

    test "middleware receives initialized options" do
      ctx = Context.new()
      opts = CustomInitMiddleware.init(prefix: "test-prefix")

      {:ok, result_ctx} =
        CustomInitMiddleware.call(ctx, opts, fn ctx ->
          {:ok, ctx}
        end)

      assert Context.get_assign(result_ctx, :prefix) == "test-prefix"
    end
  end
end

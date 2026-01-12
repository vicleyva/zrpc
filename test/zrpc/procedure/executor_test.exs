defmodule Zrpc.Procedure.ExecutorTest do
  use ExUnit.Case, async: true

  alias Zrpc.Context
  alias Zrpc.Procedure.{Definition, Executor}

  # Test procedures module
  defmodule TestProcedures do
    use Zrpc.Procedure

    query :simple do
      handler(fn input, _ctx ->
        {:ok, %{received: input}}
      end)
    end

    query :with_input_validation do
      input(
        Zoi.object(%{
          name: Zoi.string() |> Zoi.min(2),
          age: Zoi.integer() |> Zoi.positive()
        })
      )

      handler(fn input, _ctx ->
        {:ok, input}
      end)
    end

    query :with_output_validation do
      output(
        Zoi.object(%{
          id: Zoi.string(),
          name: Zoi.string()
        })
      )

      handler(fn _input, _ctx ->
        {:ok, %{id: "123", name: "Test"}}
      end)
    end

    query :returns_error do
      handler(fn _input, _ctx ->
        {:error, :not_found}
      end)
    end

    query :returns_error_with_message do
      handler(fn _input, _ctx ->
        {:error, :validation_error, "Name is required"}
      end)
    end

    query :raises_exception do
      handler(fn _input, _ctx ->
        raise "Something went wrong"
      end)
    end

    query :with_middleware do
      middleware(Zrpc.Procedure.ExecutorTest.AddValueMiddleware)
      middleware(Zrpc.Procedure.ExecutorTest.MultiplyMiddleware, factor: 2)

      handler(fn _input, ctx ->
        {:ok, %{value: Context.get_assign(ctx, :value)}}
      end)
    end

    # For testing implicit handlers
    query :implicit do
      input(Zoi.object(%{value: Zoi.string()}))
    end

    def implicit(%{value: value}, _ctx) do
      {:ok, %{result: "implicit: #{value}"}}
    end
  end

  defmodule AddValueMiddleware do
    use Zrpc.Middleware

    @impl true
    def call(ctx, _opts, next) do
      ctx = Context.assign(ctx, :value, 10)
      next.(ctx)
    end
  end

  defmodule MultiplyMiddleware do
    use Zrpc.Middleware

    @impl true
    def init(opts) do
      %{factor: Keyword.get(opts, :factor, 1)}
    end

    @impl true
    def call(ctx, opts, next) do
      current = Context.get_assign(ctx, :value, 0)
      ctx = Context.assign(ctx, :value, current * opts.factor)
      next.(ctx)
    end
  end

  defmodule ShortCircuitMiddleware do
    use Zrpc.Middleware

    @impl true
    def call(_ctx, _opts, _next) do
      {:error, :forbidden}
    end
  end

  describe "execute/4 basic execution" do
    test "executes simple procedure" do
      proc = TestProcedures.__zrpc_procedure__(:simple)
      ctx = Context.new()

      assert {:ok, result} = Executor.execute(proc, %{key: "value"}, ctx)
      assert result == %{received: %{key: "value"}}
    end

    test "passes empty map when input is nil" do
      proc = TestProcedures.__zrpc_procedure__(:simple)
      ctx = Context.new()

      assert {:ok, result} = Executor.execute(proc, nil, ctx)
      assert result == %{received: %{}}
    end
  end

  describe "execute/4 input validation" do
    test "validates input and passes validated data to handler" do
      proc = TestProcedures.__zrpc_procedure__(:with_input_validation)
      ctx = Context.new()

      assert {:ok, result} = Executor.execute(proc, %{"name" => "John", "age" => 25}, ctx)
      assert result.name == "John"
      assert result.age == 25
    end

    test "returns error for invalid input" do
      proc = TestProcedures.__zrpc_procedure__(:with_input_validation)
      ctx = Context.new()

      assert {:error, error} = Executor.execute(proc, %{"name" => "J", "age" => -5}, ctx)
      assert error.code == :validation_error
      assert error.message == "Validation failed"
      assert is_map(error.details)
    end
  end

  describe "execute/4 output validation" do
    test "validates output when enabled" do
      proc = TestProcedures.__zrpc_procedure__(:with_output_validation)
      ctx = Context.new()

      assert {:ok, result} = Executor.execute(proc, %{}, ctx)
      assert result.id == "123"
      assert result.name == "Test"
    end

    test "skips output validation when disabled via options" do
      proc = TestProcedures.__zrpc_procedure__(:with_output_validation)
      ctx = Context.new()

      assert {:ok, _result} = Executor.execute(proc, %{}, ctx, validate_output: false)
    end
  end

  describe "execute/4 error handling" do
    test "handles error atom return" do
      proc = TestProcedures.__zrpc_procedure__(:returns_error)
      ctx = Context.new()

      assert {:error, error} = Executor.execute(proc, %{}, ctx)
      assert error.code == :not_found
    end

    test "handles error with message return" do
      proc = TestProcedures.__zrpc_procedure__(:returns_error_with_message)
      ctx = Context.new()

      assert {:error, error} = Executor.execute(proc, %{}, ctx)
      assert error.code == :validation_error
      assert error.message == "Name is required"
    end

    test "catches and formats exceptions" do
      proc = TestProcedures.__zrpc_procedure__(:raises_exception)
      ctx = Context.new()

      assert {:error, error} = Executor.execute(proc, %{}, ctx)
      assert error.code == :internal_error
      assert error.message == "Internal server error"
    end
  end

  describe "execute/4 middleware chain" do
    test "runs middleware in order" do
      proc = TestProcedures.__zrpc_procedure__(:with_middleware)
      ctx = Context.new()

      assert {:ok, result} = Executor.execute(proc, %{}, ctx)
      # AddValueMiddleware sets 10, MultiplyMiddleware multiplies by 2
      assert result.value == 20
    end

    test "middleware can short-circuit the chain" do
      # Create a procedure with short-circuit middleware
      proc = %Definition{
        name: :test_short_circuit,
        type: :query,
        handler: fn _input, _ctx -> {:ok, %{should_not_reach: true}} end,
        middleware: [ShortCircuitMiddleware],
        __source__: %{file: "test", line: 1, module: __MODULE__}
      }

      ctx = Context.new()

      assert {:error, :forbidden} = Executor.execute(proc, %{}, ctx)
    end
  end

  describe "execute/4 implicit handler" do
    test "calls module function when handler is nil" do
      proc = TestProcedures.__zrpc_procedure__(:implicit)
      ctx = Context.new()

      assert {:ok, result} = Executor.execute(proc, %{"value" => "test"}, ctx)
      assert result.result == "implicit: test"
    end
  end

  describe "execute/4 hooks" do
    defmodule TestHooks do
      def before_hook(ctx, _raw_input, _proc) do
        ctx = Context.assign(ctx, :before_ran, true)
        {:ok, ctx}
      end

      def after_hook(_ctx, output, _proc) do
        {:ok, Map.put(output, :after_ran, true)}
      end

      def failing_before_hook(_ctx, _raw_input, _proc) do
        {:error, :hook_failed}
      end
    end

    test "runs before hooks" do
      proc = %Definition{
        name: :test_hooks,
        type: :query,
        handler: fn _input, ctx ->
          {:ok, %{before_ran: Context.get_assign(ctx, :before_ran)}}
        end,
        __source__: %{file: "test", line: 1, module: __MODULE__}
      }

      ctx = Context.new()
      opts = [before_hooks: [{TestHooks, :before_hook}]]

      assert {:ok, result} = Executor.execute(proc, %{}, ctx, opts)
      assert result.before_ran == true
    end

    test "runs after hooks" do
      proc = %Definition{
        name: :test_hooks,
        type: :query,
        handler: fn _input, _ctx -> {:ok, %{value: 1}} end,
        __source__: %{file: "test", line: 1, module: __MODULE__}
      }

      ctx = Context.new()
      opts = [after_hooks: [{TestHooks, :after_hook}]]

      assert {:ok, result} = Executor.execute(proc, %{}, ctx, opts)
      assert result.after_ran == true
    end

    test "before hook can short-circuit execution" do
      proc = %Definition{
        name: :test_hooks,
        type: :query,
        handler: fn _input, _ctx -> {:ok, %{should_not_reach: true}} end,
        __source__: %{file: "test", line: 1, module: __MODULE__}
      }

      ctx = Context.new()
      opts = [before_hooks: [{TestHooks, :failing_before_hook}]]

      assert {:error, :hook_failed} = Executor.execute(proc, %{}, ctx, opts)
    end
  end

  describe "execute/4 telemetry" do
    test "emits start and stop events on success" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:zrpc, :procedure, :start],
          [:zrpc, :procedure, :stop]
        ])

      proc = TestProcedures.__zrpc_procedure__(:simple)
      ctx = Context.new()

      {:ok, _} = Executor.execute(proc, %{}, ctx)

      assert_receive {[:zrpc, :procedure, :start], ^ref, %{system_time: _}, %{procedure: :simple}}
      assert_receive {[:zrpc, :procedure, :stop], ^ref, %{duration: _}, %{procedure: :simple}}
    end

    test "emits start and exception events on error" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:zrpc, :procedure, :start],
          [:zrpc, :procedure, :exception]
        ])

      proc = TestProcedures.__zrpc_procedure__(:returns_error)
      ctx = Context.new()

      {:error, _} = Executor.execute(proc, %{}, ctx)

      assert_receive {[:zrpc, :procedure, :start], ^ref, %{system_time: _},
                      %{procedure: :returns_error}}

      assert_receive {[:zrpc, :procedure, :exception], ^ref, %{duration: _},
                      %{procedure: :returns_error, kind: :error}}
    end
  end
end

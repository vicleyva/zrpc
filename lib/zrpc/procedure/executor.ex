defmodule Zrpc.Procedure.Executor do
  @moduledoc """
  Executes a procedure with:
  - Before hooks
  - Input validation (via Zoi)
  - Inline middleware chain
  - Handler execution with try/catch
  - Output validation (via Zoi, configurable)
  - After hooks
  - Telemetry events throughout
  """

  alias Zrpc.Procedure.Definition
  alias Zrpc.Context

  require Logger

  @doc """
  Executes a procedure with the given input and context.

  Returns:
  - `{:ok, validated_output}` on success
  - `{:error, error}` on failure

  ## Execution Flow

  1. Emit `[:zrpc, :procedure, :start]` telemetry
  2. Run before hooks
  3. Validate input against schema
  4. Run inline middleware chain
  5. Execute handler (wrapped in try/catch)
  6. Validate output against schema (if enabled)
  7. Run after hooks
  8. Emit `[:zrpc, :procedure, :stop]` or `[:zrpc, :procedure, :exception]` telemetry

  ## Options

  - `:before_hooks` - List of `{module, function}` tuples called before validation
  - `:after_hooks` - List of `{module, function}` tuples called after output
  - `:validate_output` - Boolean to override output validation

  ## Telemetry Events

  - `[:zrpc, :procedure, :start]` - Emitted when procedure execution starts
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{procedure: atom, type: atom, module: module}`

  - `[:zrpc, :procedure, :stop]` - Emitted on successful completion
    - Measurements: `%{duration: integer}` (native time units)
    - Metadata: `%{procedure: atom, type: atom, module: module}`

  - `[:zrpc, :procedure, :exception]` - Emitted on error
    - Measurements: `%{duration: integer}`
    - Metadata: `%{procedure: atom, type: atom, module: module, kind: atom, reason: term}`
  """
  @spec execute(Definition.t(), map(), Context.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute(%Definition{} = proc, raw_input, %Context{} = ctx, opts \\ []) do
    start_time = System.monotonic_time()
    metadata = build_telemetry_metadata(proc)

    :telemetry.execute(
      [:zrpc, :procedure, :start],
      %{system_time: System.system_time()},
      metadata
    )

    result =
      with {:ok, ctx} <- run_before_hooks(opts[:before_hooks] || [], ctx, raw_input, proc),
           {:ok, input} <- validate_input(proc, raw_input),
           {:ok, ctx} <- run_middleware_chain(proc.middleware, ctx),
           {:ok, output} <- execute_handler(proc, input, ctx),
           {:ok, validated_output} <- maybe_validate_output(proc, output, opts),
           {:ok, final_output} <-
             run_after_hooks(opts[:after_hooks] || [], ctx, validated_output, proc) do
        {:ok, final_output}
      end

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, _} ->
        :telemetry.execute(
          [:zrpc, :procedure, :stop],
          %{duration: duration},
          metadata
        )

      {:error, error} ->
        :telemetry.execute(
          [:zrpc, :procedure, :exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: error})
        )
    end

    result
  end

  defp build_telemetry_metadata(%{name: name, type: type, __source__: %{module: module}}) do
    %{procedure: name, type: type, module: module}
  end

  # Before Hooks - called before input validation
  # Hook signature: hook(ctx, raw_input, procedure) :: {:ok, ctx} | {:error, reason}

  defp run_before_hooks([], ctx, _raw_input, _proc), do: {:ok, ctx}

  defp run_before_hooks([{mod, fun} | rest], ctx, raw_input, proc) do
    case apply(mod, fun, [ctx, raw_input, proc]) do
      {:ok, ctx} -> run_before_hooks(rest, ctx, raw_input, proc)
      {:error, _} = error -> error
    end
  end

  # After Hooks - called after output validation
  # Hook signature: hook(ctx, output, procedure) :: {:ok, output} | {:error, reason}

  defp run_after_hooks([], _ctx, output, _proc), do: {:ok, output}

  defp run_after_hooks([{mod, fun} | rest], ctx, output, proc) do
    case apply(mod, fun, [ctx, output, proc]) do
      {:ok, output} -> run_after_hooks(rest, ctx, output, proc)
      {:error, _} = error -> error
    end
  end

  # Input Validation

  defp validate_input(%{input: nil}, raw_input) do
    # No schema defined, pass through (default to empty map if nil)
    {:ok, raw_input || %{}}
  end

  defp validate_input(%{input: schema}, raw_input) do
    # Enable coercion for string keys (JSON input typically has string keys)
    schema_with_coerce = Zoi.coerce(schema)

    case Zoi.parse(schema_with_coerce, raw_input || %{}) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, format_validation_error(errors)}
    end
  end

  # Middleware Chain

  defp run_middleware_chain([], ctx), do: {:ok, ctx}

  defp run_middleware_chain([middleware | rest], ctx) do
    {mod, opts} = normalize_middleware(middleware)

    case apply(mod, :call, [ctx, opts, fn ctx -> run_middleware_chain(rest, ctx) end]) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, _} = error -> error
    end
  end

  defp normalize_middleware({mod, opts}) when is_atom(mod) and is_list(opts) do
    {mod, mod.init(opts)}
  end

  defp normalize_middleware(mod) when is_atom(mod) do
    {mod, mod.init([])}
  end

  # Handler Execution with Exception Handling

  defp execute_handler(%{handler: nil, name: name, __source__: %{module: module}}, input, ctx) do
    # Implicit handler: call the module function with procedure name
    execute_handler_fn(&apply(module, name, [&1, &2]), name, input, ctx)
  end

  defp execute_handler(%{handler: handler, name: name}, input, ctx) do
    execute_handler_fn(handler, name, input, ctx)
  end

  defp execute_handler_fn(handler, name, input, ctx) do
    try do
      case handler.(input, ctx) do
        {:ok, result} ->
          {:ok, result}

        {:error, code} when is_atom(code) ->
          {:error, %{code: code}}

        {:error, code, message} when is_atom(code) ->
          {:error, %{code: code, message: message}}

        {:error, %{} = error} ->
          {:error, error}

        other ->
          Logger.warning("[Zrpc] Procedure #{name} returned unexpected value: #{inspect(other)}")

          {:error, %{code: :internal_error, message: "Unexpected handler return value"}}
      end
    rescue
      e ->
        Logger.error(
          "[Zrpc] Procedure #{name} raised exception: #{Exception.format(:error, e, __STACKTRACE__)}"
        )

        {:error,
         %{
           code: :internal_error,
           message: "Internal server error",
           # Include exception details based on config (not in production by default)
           __exception__:
             if(include_exception_details?(),
               do: Exception.format(:error, e, __STACKTRACE__),
               else: nil
             )
         }}
    end
  end

  defp include_exception_details? do
    Application.get_env(:zrpc, :include_exception_details, false)
  end

  # Output Validation (Configurable)
  #
  # Output validation can be controlled at three levels (precedence order):
  # 1. Per-call option: execute(proc, input, ctx, validate_output: false)
  # 2. Per-procedure meta: meta validate_output: false
  # 3. Global config: config :zrpc, validate_output: true (default)

  defp maybe_validate_output(proc, output, opts) do
    if should_validate_output?(proc, opts) do
      validate_output(proc, output)
    else
      {:ok, output}
    end
  end

  defp should_validate_output?(proc, opts) do
    cond do
      # Per-call option takes highest precedence
      Keyword.has_key?(opts, :validate_output) ->
        Keyword.get(opts, :validate_output)

      # Per-procedure meta takes second precedence
      Map.has_key?(proc.meta, :validate_output) ->
        proc.meta[:validate_output]

      # Global config is the fallback (defaults to true)
      true ->
        Application.get_env(:zrpc, :validate_output, true)
    end
  end

  defp validate_output(%{output: nil}, output) do
    # No schema defined, pass through
    {:ok, output}
  end

  defp validate_output(%{output: schema, name: name}, output) do
    case Zoi.parse(schema, output) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        # Log the error but don't expose internal schema mismatch to client
        Logger.error("[Zrpc] Procedure #{name} output validation failed: #{inspect(errors)}")
        Logger.error("[Zrpc] Output was: #{inspect(output)}")
        {:error, %{code: :internal_error, message: "Response validation failed"}}
    end
  end

  # Error Formatting

  defp format_validation_error(errors) do
    %{
      code: :validation_error,
      message: "Validation failed",
      details: format_zoi_errors(errors)
    }
  end

  defp format_zoi_errors(errors) when is_list(errors) do
    Enum.reduce(errors, %{}, fn error, acc ->
      path = get_error_path(error)
      key = if path == [], do: "_root", else: Enum.join(path, ".")
      messages = Map.get(acc, key, [])
      message = get_error_message(error)
      Map.put(acc, key, messages ++ [message])
    end)
  end

  defp format_zoi_errors(errors), do: errors

  defp get_error_path(error) when is_map(error), do: Map.get(error, :path, [])
  defp get_error_path(_), do: []

  defp get_error_message(error) when is_map(error), do: Map.get(error, :message, "Invalid value")
  defp get_error_message(_), do: "Invalid value"
end

defmodule Zrpc.Procedure.Definition do
  @moduledoc """
  Represents a single RPC procedure (query, mutation, or subscription).

  This struct is created at compile time and stored in module attributes.
  It contains all the information needed to:
  - Validate incoming requests (input schema)
  - Validate outgoing responses (output schema)
  - Execute the handler function
  - Generate documentation and TypeScript types
  """

  @type procedure_type :: :query | :mutation | :subscription

  @type meta :: %{
          optional(:description) => String.t(),
          optional(:tags) => [String.t()],
          optional(:examples) => [map()],
          optional(:deprecated) => boolean() | String.t(),
          optional(:summary) => String.t(),
          optional(:operation_id) => String.t(),
          optional(:validate_output) => boolean()
        }

  @type route :: %{
          method: :get | :post | :put | :patch | :delete,
          path: String.t()
        }

  @type middleware_spec :: module() | {module(), keyword()}

  @type t :: %__MODULE__{
          name: atom(),
          type: procedure_type(),
          input: term() | nil,
          output: term() | nil,
          handler: (map(), Zrpc.Context.t() -> {:ok, term()} | {:error, term()}) | nil,
          meta: meta(),
          route: route() | nil,
          middleware: [middleware_spec()],
          __source__: %{file: String.t(), line: non_neg_integer(), module: module() | nil}
        }

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    :input,
    :output,
    :handler,
    :route,
    meta: %{},
    middleware: [],
    __source__: %{file: "unknown", line: 0, module: nil}
  ]

  @doc """
  Creates a new Definition from a map of attributes.
  Raises if required fields are missing.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Validates a procedure definition at compile time.
  Returns :ok or raises CompileError.

  The handler_ast parameter is the quoted handler expression stored separately
  (since anonymous functions cannot be escaped with Macro.escape).

  Note: Handler validation for implicit handlers (nil handler_ast) is deferred
  to allow functions defined after the procedure macro to be used.
  """
  @spec validate!(t(), term(), Macro.Env.t()) :: :ok
  def validate!(%__MODULE__{} = proc, handler_ast, env) do
    validate_name!(proc)
    validate_type!(proc)
    validate_handler!(proc, handler_ast, env)
    validate_route!(proc)
    :ok
  end

  defp validate_name!(%{name: name}) when is_atom(name), do: :ok

  defp validate_name!(%{name: name, __source__: source}) do
    raise CompileError,
      file: source.file,
      line: source.line,
      description: "Procedure name must be an atom, got: #{inspect(name)}"
  end

  defp validate_type!(%{type: type}) when type in [:query, :mutation, :subscription], do: :ok

  defp validate_type!(%{type: type, __source__: source}) do
    raise CompileError,
      file: source.file,
      line: source.line,
      description:
        "Procedure type must be :query, :mutation, or :subscription, got: #{inspect(type)}"
  end

  # Handler is provided as AST (not nil)
  defp validate_handler!(_proc, handler_ast, _env) when handler_ast != nil, do: :ok

  # No handler AST - check for implicit handler (module function with same name)
  defp validate_handler!(%{name: name}, nil, env) do
    # Implicit handler: check if module function exists
    # This runs at @before_compile time, so the function should be defined
    unless Module.defines?(env.module, {name, 2}) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: """
        Procedure :#{name} has no handler defined.

        Either add an inline handler:

            query :#{name} do
              handler fn input, ctx -> {:ok, result} end
            end

        Or define a function with the same name:

            query :#{name} do
              input ...
            end

            def #{name}(input, ctx) do
              {:ok, result}
            end
        """
    end

    :ok
  end

  defp validate_route!(%{route: nil}), do: :ok

  defp validate_route!(%{route: %{method: method, path: path}})
       when method in [:get, :post, :put, :patch, :delete] and is_binary(path),
       do: :ok

  defp validate_route!(%{route: route, __source__: source}) do
    raise CompileError,
      file: source.file,
      line: source.line,
      description: "Invalid route definition: #{inspect(route)}"
  end

  @doc """
  Returns the JSON Schema for the input (placeholder for Zoi integration).
  """
  @spec input_json_schema(t()) :: map() | nil
  def input_json_schema(%__MODULE__{input: nil}), do: nil

  def input_json_schema(%__MODULE__{input: _schema}) do
    # TODO: Use Zoi.to_json_schema when available
    %{"type" => "object"}
  end

  @doc """
  Returns the JSON Schema for the output (placeholder for Zoi integration).
  """
  @spec output_json_schema(t()) :: map() | nil
  def output_json_schema(%__MODULE__{output: nil}), do: nil

  def output_json_schema(%__MODULE__{output: _schema}) do
    # TODO: Use Zoi.to_json_schema when available
    %{"type" => "object"}
  end

  @doc """
  Returns a unique identifier for this procedure.
  """
  @spec procedure_id(t()) :: String.t()
  def procedure_id(%__MODULE__{name: name}), do: Atom.to_string(name)

  @doc """
  Returns whether this is a query procedure.
  """
  @spec query?(t()) :: boolean()
  def query?(%__MODULE__{type: :query}), do: true
  def query?(_), do: false

  @doc """
  Returns whether this is a mutation procedure.
  """
  @spec mutation?(t()) :: boolean()
  def mutation?(%__MODULE__{type: :mutation}), do: true
  def mutation?(_), do: false

  @doc """
  Returns whether this is a subscription procedure.
  """
  @spec subscription?(t()) :: boolean()
  def subscription?(%__MODULE__{type: :subscription}), do: true
  def subscription?(_), do: false
end

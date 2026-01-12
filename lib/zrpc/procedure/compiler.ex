defmodule Zrpc.Procedure.Compiler do
  @moduledoc """
  Compile-time hook that:
  1. Validates all procedure definitions
  2. Generates introspection functions
  3. Optimizes procedure lookup with compile-time indexing

  Handles the fact that anonymous functions cannot be escaped by
  generating code that builds the procedures at compile time with
  the handlers properly injected.
  """

  alias Zrpc.Procedure.Definition

  @doc false
  defmacro __before_compile__(env) do
    procedures_data = Module.get_attribute(env.module, :zrpc_procedures) || []

    # Reverse because @accumulate prepends
    procedures_data = Enum.reverse(procedures_data)

    # Validate all procedures at compile time
    # Note: procedures_data contains {proc_without_handler, handler_ast} tuples
    Enum.each(procedures_data, fn {proc, handler_ast} ->
      Definition.validate!(proc, handler_ast, env)
    end)

    # Extract procedure names for simple queries
    procedure_names = Enum.map(procedures_data, fn {proc, _} -> proc.name end)

    # Generate code that builds the procedures list with handlers
    procedures_code =
      Enum.map(procedures_data, fn {proc, handler_ast} ->
        generate_procedure_struct(proc, handler_ast)
      end)

    # Generate lookup by name clauses
    lookup_clauses =
      Enum.map(procedures_data, fn {proc, handler_ast} ->
        quote do
          def __zrpc_procedure__(unquote(proc.name)) do
            unquote(generate_procedure_struct(proc, handler_ast))
          end
        end
      end)

    quote do
      @doc """
      Returns all procedures defined in this module.
      """
      @spec __zrpc_procedures__() :: [Zrpc.Procedure.Definition.t()]
      def __zrpc_procedures__ do
        unquote(procedures_code)
      end

      @doc """
      Returns a procedure by name, or nil if not found.
      """
      @spec __zrpc_procedure__(atom()) :: Zrpc.Procedure.Definition.t() | nil
      unquote_splicing(lookup_clauses)

      def __zrpc_procedure__(_name), do: nil

      @doc """
      Returns all query procedures.
      """
      @spec __zrpc_queries__() :: [Zrpc.Procedure.Definition.t()]
      def __zrpc_queries__ do
        Enum.filter(__zrpc_procedures__(), &(&1.type == :query))
      end

      @doc """
      Returns all mutation procedures.
      """
      @spec __zrpc_mutations__() :: [Zrpc.Procedure.Definition.t()]
      def __zrpc_mutations__ do
        Enum.filter(__zrpc_procedures__(), &(&1.type == :mutation))
      end

      @doc """
      Returns all subscription procedures.
      """
      @spec __zrpc_subscriptions__() :: [Zrpc.Procedure.Definition.t()]
      def __zrpc_subscriptions__ do
        Enum.filter(__zrpc_procedures__(), &(&1.type == :subscription))
      end

      @doc """
      Returns all procedure names.
      """
      @spec __zrpc_procedure_names__() :: [atom()]
      def __zrpc_procedure_names__ do
        unquote(procedure_names)
      end

      @doc """
      Checks if a procedure with the given name exists.
      """
      @spec __zrpc_has_procedure__?(atom()) :: boolean()
      def __zrpc_has_procedure__?(name) when is_atom(name) do
        name in unquote(procedure_names)
      end

      @doc """
      Returns the module name (for router registration).
      """
      @spec __zrpc_module__() :: module()
      def __zrpc_module__, do: __MODULE__
    end
  end

  # Generate code that builds a procedure struct with the handler injected
  defp generate_procedure_struct(proc, handler_ast) do
    # Escape the parts that can be escaped
    escapable = %{
      name: proc.name,
      type: proc.type,
      input: proc.input,
      output: proc.output,
      meta: proc.meta,
      route: proc.route,
      middleware: proc.middleware,
      __source__: proc.__source__
    }

    quote do
      %Zrpc.Procedure.Definition{
        name: unquote(escapable.name),
        type: unquote(escapable.type),
        input: unquote(Macro.escape(escapable.input)),
        output: unquote(Macro.escape(escapable.output)),
        handler: unquote(handler_ast),
        meta: unquote(Macro.escape(escapable.meta)),
        route: unquote(Macro.escape(escapable.route)),
        middleware: unquote(Macro.escape(escapable.middleware)),
        __source__: unquote(Macro.escape(escapable.__source__))
      }
    end
  end
end

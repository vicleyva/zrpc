defmodule Zrpc.Router.Compiler do
  @moduledoc """
  Compile-time hook for Zrpc.Router.

  This module:
  1. Validates all registered procedure modules
  2. Builds entries with pre-computed middleware chains
  3. Validates no duplicate paths
  4. Validates alias targets exist
  5. Generates introspection functions
  """

  alias Zrpc.Router.{Alias, Entry}

  defmacro __before_compile__(env) do
    # Get accumulated attributes
    registrations = Module.get_attribute(env.module, :zrpc_router_registrations) || []
    router_middleware = Module.get_attribute(env.module, :zrpc_router_middleware) || []
    aliases = Module.get_attribute(env.module, :zrpc_router_aliases) || []

    # Reverse because @accumulate prepends
    registrations = Enum.reverse(registrations)
    router_middleware = Enum.reverse(router_middleware)
    aliases = Enum.reverse(aliases)

    # Build entries from registrations
    entries = build_entries(registrations, router_middleware, env)

    # Validate no duplicate paths
    validate_no_duplicates!(entries, env)

    # Validate aliases
    validate_aliases!(aliases, entries, env)

    # Build lookup structures
    paths = Enum.map(entries, & &1.path) |> Enum.sort()
    modules = entries |> Enum.map(& &1.source_module) |> Enum.uniq()

    queries = Enum.filter(entries, &(&1.procedure_type == :query))
    mutations = Enum.filter(entries, &(&1.procedure_type == :mutation))
    subscriptions = Enum.filter(entries, &(&1.procedure_type == :subscription))

    # Build alias map
    alias_map = Map.new(aliases, &{&1.from, &1})

    # Generate introspection functions
    quote do
      @doc "Returns all procedure entries registered in this router."
      @spec __zrpc_entries__() :: [Zrpc.Router.Entry.t()]
      def __zrpc_entries__ do
        unquote(Macro.escape(entries))
      end

      # Generate pattern-matched clauses for O(1) lookup
      unquote(generate_entry_clauses(entries))

      @doc "Returns all registered procedure paths (sorted)."
      @spec __zrpc_paths__() :: [String.t()]
      def __zrpc_paths__ do
        unquote(paths)
      end

      @doc "Checks if a path exists in this router."
      @spec __zrpc_has_path__?(String.t()) :: boolean()
      def __zrpc_has_path__?(path) when is_binary(path) do
        path in unquote(paths)
      end

      @doc "Returns all registered procedure modules."
      @spec __zrpc_modules__() :: [module()]
      def __zrpc_modules__ do
        unquote(modules)
      end

      @doc "Returns all query entries."
      @spec __zrpc_queries__() :: [Zrpc.Router.Entry.t()]
      def __zrpc_queries__ do
        unquote(Macro.escape(queries))
      end

      @doc "Returns all mutation entries."
      @spec __zrpc_mutations__() :: [Zrpc.Router.Entry.t()]
      def __zrpc_mutations__ do
        unquote(Macro.escape(mutations))
      end

      @doc "Returns all subscription entries."
      @spec __zrpc_subscriptions__() :: [Zrpc.Router.Entry.t()]
      def __zrpc_subscriptions__ do
        unquote(Macro.escape(subscriptions))
      end

      @doc "Returns entries matching a path prefix."
      @spec __zrpc_entries_by_prefix__(String.t()) :: [Zrpc.Router.Entry.t()]
      def __zrpc_entries_by_prefix__(prefix) when is_binary(prefix) do
        Enum.filter(__zrpc_entries__(), &Zrpc.Router.Entry.matches_prefix?(&1, prefix))
      end

      # Alias functions
      @doc "Returns the alias for a path, or nil if not an alias."
      @spec __zrpc_alias__(String.t()) :: Zrpc.Router.Alias.t() | nil
      def __zrpc_alias__(path) when is_binary(path) do
        Map.get(unquote(Macro.escape(alias_map)), path)
      end

      @doc "Returns all defined aliases."
      @spec __zrpc_aliases__() :: %{String.t() => Zrpc.Router.Alias.t()}
      def __zrpc_aliases__ do
        unquote(Macro.escape(alias_map))
      end

      @doc "Resolves a path (direct or via alias) to an entry."
      @spec __zrpc_resolve__(String.t()) :: Zrpc.Router.Entry.t() | nil
      def __zrpc_resolve__(path) when is_binary(path) do
        case __zrpc_entry__(path) do
          nil ->
            case __zrpc_alias__(path) do
              nil -> nil
              %{to: canonical} -> __zrpc_entry__(canonical)
            end

          entry ->
            entry
        end
      end

      @doc "Returns the middleware chain for a path."
      @spec __zrpc_middleware__(String.t()) :: [Zrpc.Router.Entry.middleware_spec()] | nil
      def __zrpc_middleware__(path) when is_binary(path) do
        case __zrpc_entry__(path) do
          nil -> nil
          entry -> entry.middleware
        end
      end

      @doc "Returns the procedure definition for a path."
      @spec __zrpc_procedure__(String.t()) :: Zrpc.Procedure.Definition.t() | nil
      def __zrpc_procedure__(path) when is_binary(path) do
        case __zrpc_entry__(path) do
          nil -> nil
          entry -> Zrpc.Router.Entry.procedure(entry)
        end
      end

      @doc "Returns this router module name."
      @spec __zrpc_router__() :: module()
      def __zrpc_router__, do: __MODULE__
    end
  end

  # Build entries from registrations
  defp build_entries(registrations, router_middleware, env) do
    Enum.flat_map(registrations, fn registration ->
      build_entries_for_module(registration, router_middleware, env)
    end)
  end

  defp build_entries_for_module(registration, router_middleware, _env) do
    %{
      module: module,
      namespace: namespace,
      scope_prefix: scope_prefix,
      scope_middleware: scope_middleware,
      skip_middleware: skip_middleware,
      file: file,
      line: line
    } = registration

    # Validate module uses Zrpc.Procedure
    validate_procedure_module!(module, file, line)

    # Get procedures from module
    procedures = module.__zrpc_procedures__()

    # Build full path prefix
    prefix_segments =
      (scope_prefix ++ [namespace])
      |> Enum.map(fn
        segment when is_binary(segment) -> String.to_atom(segment)
        segment when is_atom(segment) -> segment
      end)

    # Build entries for each procedure
    Enum.map(procedures, fn procedure ->
      # Build full path
      path_segments = prefix_segments ++ [procedure.name]
      path = Entry.build_path(path_segments)

      # Build middleware chain: router -> scope -> procedure
      # Filter out skipped middleware
      combined_middleware =
        (router_middleware ++ scope_middleware ++ procedure.middleware)
        |> Enum.reject(fn
          {mod, _opts} -> mod in skip_middleware
          mod when is_atom(mod) -> mod in skip_middleware
        end)

      Entry.new(%{
        path: path,
        path_segments: path_segments,
        procedure_name: procedure.name,
        procedure_type: procedure.type,
        middleware: combined_middleware,
        source_module: module
      })
    end)
  end

  defp validate_procedure_module!(module, file, line) do
    # Check if module is compiled and has procedures
    unless Code.ensure_loaded?(module) do
      raise CompileError,
        file: file,
        line: line,
        description: "Module #{inspect(module)} is not available"
    end

    unless function_exported?(module, :__zrpc_procedures__, 0) do
      raise CompileError,
        file: file,
        line: line,
        description: """
        Module #{inspect(module)} does not use Zrpc.Procedure.

        Make sure to add `use Zrpc.Procedure` to the module:

            defmodule #{inspect(module)} do
              use Zrpc.Procedure

              query :my_query do
                # ...
              end
            end
        """
    end
  end

  defp validate_no_duplicates!(entries, env) do
    entries
    |> Enum.group_by(& &1.path)
    |> Enum.each(fn
      {_path, [_single]} ->
        :ok

      {path, duplicates} ->
        sources =
          Enum.map_join(duplicates, "\n", fn entry ->
            "  - #{inspect(entry.source_module)}"
          end)

        raise CompileError,
          file: env.file,
          line: env.line,
          description: """
          Duplicate procedure path "#{path}"

          Defined in:
          #{sources}

          Each procedure path must be unique within a router.
          """
    end)
  end

  defp validate_aliases!(aliases, entries, env) do
    path_set = MapSet.new(entries, & &1.path)
    _alias_from_set = MapSet.new(aliases, & &1.from)

    Enum.each(aliases, fn alias_def ->
      # Validate alias format
      case Alias.validate(alias_def) do
        :ok -> :ok
        {:error, reason} -> raise CompileError, file: env.file, description: reason
      end

      # Validate target exists
      unless MapSet.member?(path_set, alias_def.to) do
        raise CompileError,
          file: env.file,
          description: """
          Alias target not found: "#{alias_def.to}"

          The alias "#{alias_def.from}" points to a path that doesn't exist.
          Available paths: #{inspect(Enum.take(path_set, 5))}
          """
      end

      # Validate no conflict with existing paths
      if MapSet.member?(path_set, alias_def.from) do
        raise CompileError,
          file: env.file,
          description: """
          Alias conflicts with existing path: "#{alias_def.from}"

          Cannot create an alias with the same name as an existing procedure path.
          """
      end
    end)

    # Check for circular aliases (alias A -> B -> A)
    validate_no_circular_aliases!(aliases, env)
  end

  defp validate_no_circular_aliases!(aliases, env) do
    alias_map = Map.new(aliases, &{&1.from, &1.to})

    Enum.each(aliases, fn %{from: from, to: to} ->
      # Check if the target is also an alias pointing back
      check_circular(from, to, alias_map, MapSet.new([from]), env)
    end)
  end

  defp check_circular(_start, target, alias_map, visited, env) do
    case Map.get(alias_map, target) do
      nil ->
        :ok

      next_target ->
        if MapSet.member?(visited, next_target) do
          chain = [next_target | MapSet.to_list(visited)] |> Enum.reverse() |> Enum.join(" -> ")

          raise CompileError,
            file: env.file,
            description: "Circular alias detected: #{chain}"
        else
          check_circular(target, next_target, alias_map, MapSet.put(visited, target), env)
        end
    end
  end

  # Generate pattern-matched function clauses for efficient lookup
  defp generate_entry_clauses(entries) do
    clauses =
      Enum.map(entries, fn entry ->
        quote do
          def __zrpc_entry__(unquote(entry.path)) do
            unquote(Macro.escape(entry))
          end
        end
      end)

    # Add catch-all clause
    catch_all =
      quote do
        @doc "Returns the entry for a path, or nil if not found."
        @spec __zrpc_entry__(String.t()) :: Zrpc.Router.Entry.t() | nil
        def __zrpc_entry__(_), do: nil
      end

    clauses ++ [catch_all]
  end
end

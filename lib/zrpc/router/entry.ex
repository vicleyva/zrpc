defmodule Zrpc.Router.Entry do
  @moduledoc """
  Represents a procedure registered in a router.

  An entry contains the full path, procedure metadata (type and name),
  the pre-computed middleware chain, and the source module where the procedure was defined.

  The actual procedure Definition (with handler function) is looked up at runtime
  from the source module to avoid issues with anonymous functions in compile-time AST.

  ## Fields

  - `path` - Full dotted path string (e.g., "admin.users.get_user")
  - `path_segments` - List of atoms for fast matching (e.g., [:admin, :users, :get_user])
  - `procedure_name` - The atom name of the procedure (e.g., :get_user)
  - `procedure_type` - The type (:query, :mutation, or :subscription)
  - `middleware` - Pre-computed middleware chain (router + scope + procedure level)
  - `source_module` - The procedure module (e.g., MyApp.Procedures.Users)
  """

  @type middleware_spec :: module() | {module(), keyword()}

  @type t :: %__MODULE__{
          path: String.t(),
          path_segments: [atom()],
          procedure_name: atom(),
          procedure_type: :query | :mutation | :subscription,
          middleware: [middleware_spec()],
          source_module: module()
        }

  @enforce_keys [:path, :path_segments, :procedure_name, :procedure_type, :source_module]
  defstruct [
    :path,
    :path_segments,
    :procedure_name,
    :procedure_type,
    :source_module,
    middleware: []
  ]

  @doc """
  Creates a new Entry from a map of attributes.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Builds a path string from segments.

  ## Examples

      iex> Entry.build_path([:users, :get_user])
      "users.get_user"

      iex> Entry.build_path([:admin, :users, :list])
      "admin.users.list"
  """
  @spec build_path([atom()]) :: String.t()
  def build_path(segments) when is_list(segments) do
    Enum.map_join(segments, ".", &Atom.to_string/1)
  end

  @doc """
  Parses a path string into segments.

  ## Examples

      iex> Entry.parse_path("users.get_user")
      [:users, :get_user]

      iex> Entry.parse_path("admin.users.list")
      [:admin, :users, :list]
  """
  @spec parse_path(String.t()) :: [atom()]
  def parse_path(path) when is_binary(path) do
    path
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  @doc """
  Validates a path string format.

  Valid paths:
  - Contain only lowercase letters, numbers, and underscores
  - Segments separated by dots
  - No empty segments, no leading/trailing dots
  - Must start with a letter

  ## Examples

      iex> Entry.valid_path?("users.get_user")
      true

      iex> Entry.valid_path?("admin.users.list_all")
      true

      iex> Entry.valid_path?("Users.Get")
      false

      iex> Entry.valid_path?("users..get")
      false
  """
  @spec valid_path?(String.t()) :: boolean()
  def valid_path?(path) when is_binary(path) do
    Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/, path)
  end

  @doc """
  Looks up and returns the full procedure Definition at runtime.

  This is done at runtime because procedure Definitions contain anonymous
  functions (handlers) which cannot be stored in compile-time AST.
  """
  @spec procedure(t()) :: Zrpc.Procedure.Definition.t()
  def procedure(%__MODULE__{source_module: module, procedure_name: name}) do
    module.__zrpc_procedure__(name)
  end

  @doc """
  Returns the procedure type (:query, :mutation, or :subscription).
  """
  @spec type(t()) :: :query | :mutation | :subscription
  def type(%__MODULE__{procedure_type: type}), do: type

  @doc """
  Returns the procedure name (atom).
  """
  @spec name(t()) :: atom()
  def name(%__MODULE__{procedure_name: name}), do: name

  @doc """
  Checks if this entry matches a given prefix.

  ## Examples

      iex> entry = %Entry{path: "admin.users.get", ...}
      iex> Entry.matches_prefix?(entry, "admin")
      true

      iex> Entry.matches_prefix?(entry, "admin.users")
      true

      iex> Entry.matches_prefix?(entry, "posts")
      false
  """
  @spec matches_prefix?(t(), String.t()) :: boolean()
  def matches_prefix?(%__MODULE__{path: path}, prefix) when is_binary(prefix) do
    String.starts_with?(path, prefix <> ".") or path == prefix
  end
end

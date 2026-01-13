defmodule Zrpc.Router.Alias do
  @moduledoc """
  Represents a path alias in a router.

  Aliases allow defining alternative names for procedures, useful for:
  - Backwards compatibility after renaming procedures
  - Convenience shortcuts
  - API versioning

  ## Fields

  - `from` - The alias path (what clients can call)
  - `to` - The canonical path (the actual procedure)
  - `deprecated` - Whether this alias is deprecated (triggers telemetry/logging)

  ## Example

      # In router definition
      alias "users.get_user", to: "users.get"
      alias "getUser", to: "users.get", deprecated: true
  """

  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t(),
          deprecated: boolean()
        }

  @enforce_keys [:from, :to]
  defstruct [
    :from,
    :to,
    deprecated: false
  ]

  @doc """
  Creates a new Alias from a map of attributes.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Creates a new Alias from keyword options.

  ## Examples

      iex> Alias.from_opts("old.path", to: "new.path")
      %Alias{from: "old.path", to: "new.path", deprecated: false}

      iex> Alias.from_opts("legacy.api", to: "v2.api", deprecated: true)
      %Alias{from: "legacy.api", to: "v2.api", deprecated: true}
  """
  @spec from_opts(String.t(), keyword()) :: t()
  def from_opts(from, opts) when is_binary(from) and is_list(opts) do
    %__MODULE__{
      from: from,
      to: Keyword.fetch!(opts, :to),
      deprecated: Keyword.get(opts, :deprecated, false)
    }
  end

  @doc """
  Validates an alias definition.

  Returns `:ok` or `{:error, reason}`.

  Validation rules:
  - `from` must be a valid path format
  - `to` must be a valid path format
  - `from` and `to` must be different
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{from: from, to: to}) do
    cond do
      not valid_path_format?(from) ->
        {:error, "Invalid alias path format: #{inspect(from)}"}

      not valid_path_format?(to) ->
        {:error, "Invalid target path format: #{inspect(to)}"}

      from == to ->
        {:error, "Alias cannot point to itself: #{inspect(from)}"}

      true ->
        :ok
    end
  end

  @doc """
  Checks if a path string has valid format for aliases.

  Alias paths can use camelCase (for backwards compat with JS clients)
  in addition to snake_case, so we're more permissive than Entry paths.
  """
  @spec valid_path_format?(String.t()) :: boolean()
  def valid_path_format?(path) when is_binary(path) do
    # Allow letters (any case), numbers, underscores, and dots
    # Must start with a letter, no empty segments
    Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)*$/, path)
  end
end

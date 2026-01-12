defmodule Zrpc.Procedure.MetaParser do
  @moduledoc """
  Parses meta block AST at compile time to extract metadata.

  Supports block syntax:

      meta do
        description "User retrieval"
        tags ["users", "public"]
        examples [%{id: "123"}]
        deprecated "Use get_user_v2 instead"
      end

  And inline/keyword syntax:

      meta description: "User retrieval", tags: ["users"]
  """

  @doc """
  Parses a meta block or keyword list into a map.
  """
  @spec parse(term()) :: map()
  def parse({:__block__, _, statements}) do
    Enum.reduce(statements, %{}, &parse_statement/2)
  end

  def parse(single_statement) when is_tuple(single_statement) do
    parse_statement(single_statement, %{})
  end

  def parse(keyword_list) when is_list(keyword_list) do
    Enum.into(keyword_list, %{})
  end

  def parse(_), do: %{}

  # Parse individual statements

  defp parse_statement({:description, _, [text]}, acc) when is_binary(text) do
    Map.put(acc, :description, text)
  end

  defp parse_statement({:tags, _, [list]}, acc) when is_list(list) do
    Map.put(acc, :tags, list)
  end

  defp parse_statement({:examples, _, [list]}, acc) when is_list(list) do
    Map.put(acc, :examples, list)
  end

  defp parse_statement({:example, _, [value]}, acc) do
    # Single example - wrap in list or append to existing
    existing = Map.get(acc, :examples, [])
    Map.put(acc, :examples, existing ++ [value])
  end

  defp parse_statement({:deprecated, _, [value]}, acc) do
    Map.put(acc, :deprecated, value)
  end

  defp parse_statement({:summary, _, [text]}, acc) when is_binary(text) do
    # Alias for short description (OpenAPI compat)
    Map.put(acc, :summary, text)
  end

  defp parse_statement({:operation_id, _, [id]}, acc) when is_binary(id) do
    # Custom operation ID for OpenAPI
    Map.put(acc, :operation_id, id)
  end

  defp parse_statement({:validate_output, _, [value]}, acc) when is_boolean(value) do
    # Control output validation for this procedure
    Map.put(acc, :validate_output, value)
  end

  defp parse_statement(_unknown, acc) do
    # Ignore unknown statements to allow forward compatibility
    acc
  end
end

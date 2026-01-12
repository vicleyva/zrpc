defmodule Zrpc.Procedure.MetaParserTest do
  use ExUnit.Case, async: true

  alias Zrpc.Procedure.MetaParser

  describe "parse/1 with block syntax" do
    test "parses description" do
      ast = {:description, [], ["Get a user by ID"]}
      result = MetaParser.parse(ast)
      assert result == %{description: "Get a user by ID"}
    end

    test "parses tags" do
      ast = {:tags, [], [["users", "public"]]}
      result = MetaParser.parse(ast)
      assert result == %{tags: ["users", "public"]}
    end

    test "parses examples list" do
      ast = {:examples, [], [[%{id: "123"}, %{id: "456"}]]}
      result = MetaParser.parse(ast)
      assert result == %{examples: [%{id: "123"}, %{id: "456"}]}
    end

    test "parses single example" do
      ast = {:example, [], [%{id: "123"}]}
      result = MetaParser.parse(ast)
      assert result == %{examples: [%{id: "123"}]}
    end

    test "parses deprecated with message" do
      ast = {:deprecated, [], ["Use v2 instead"]}
      result = MetaParser.parse(ast)
      assert result == %{deprecated: "Use v2 instead"}
    end

    test "parses deprecated with boolean" do
      ast = {:deprecated, [], [true]}
      result = MetaParser.parse(ast)
      assert result == %{deprecated: true}
    end

    test "parses summary" do
      ast = {:summary, [], ["Brief summary"]}
      result = MetaParser.parse(ast)
      assert result == %{summary: "Brief summary"}
    end

    test "parses operation_id" do
      ast = {:operation_id, [], ["getUserById"]}
      result = MetaParser.parse(ast)
      assert result == %{operation_id: "getUserById"}
    end

    test "parses validate_output" do
      ast = {:validate_output, [], [false]}
      result = MetaParser.parse(ast)
      assert result == %{validate_output: false}
    end

    test "parses multiple statements in block" do
      ast =
        {:__block__, [],
         [
           {:description, [], ["Get a user"]},
           {:tags, [], [["users"]]},
           {:deprecated, [], [true]}
         ]}

      result = MetaParser.parse(ast)

      assert result == %{
               description: "Get a user",
               tags: ["users"],
               deprecated: true
             }
    end

    test "ignores unknown statements" do
      ast =
        {:__block__, [],
         [
           {:description, [], ["Test"]},
           {:unknown_directive, [], ["ignored"]}
         ]}

      result = MetaParser.parse(ast)
      assert result == %{description: "Test"}
    end
  end

  describe "parse/1 with keyword syntax" do
    test "parses keyword list" do
      result = MetaParser.parse(description: "Test", tags: ["a", "b"])
      assert result == %{description: "Test", tags: ["a", "b"]}
    end
  end

  describe "parse/1 edge cases" do
    test "returns empty map for unexpected input" do
      assert MetaParser.parse(nil) == %{}
      assert MetaParser.parse("string") == %{}
      assert MetaParser.parse(123) == %{}
    end
  end
end

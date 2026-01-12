defmodule ZrpcTest do
  use ExUnit.Case
  doctest Zrpc

  test "greets the world" do
    assert Zrpc.hello() == :world
  end
end

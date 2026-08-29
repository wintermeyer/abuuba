defmodule AbuubaWeb.API.NestedParamsTest do
  @moduledoc """
  The two spellings of a nested list, and what each caller does with rubbish.

  The helper exists because three endpoints had grown their own version of the
  reshaping and a fourth had none. It deliberately does no validating: the
  first attempt at it dropped every entry that was not a map, which read as
  tidy and turned "that profile field is invalid" into a 200 that emptied
  somebody's links. So the policy tests here are as much the point as the
  reshaping ones.
  """
  use AbuubaWeb.ConnCase, async: true

  alias AbuubaWeb.API.NestedParams

  describe "list/1" do
    test "leaves a list alone" do
      assert NestedParams.list([%{"a" => 1}, %{"b" => 2}]) == [%{"a" => 1}, %{"b" => 2}]
    end

    test "unwraps a map keyed by the index" do
      assert NestedParams.list(%{"1" => %{"b" => 2}, "0" => %{"a" => 1}}) ==
               [%{"a" => 1}, %{"b" => 2}]
    end

    test "in number order rather than string order" do
      numbered = for n <- 0..11, into: %{}, do: {to_string(n), %{"n" => n}}

      assert NestedParams.list(numbered) |> Enum.map(& &1["n"]) == Enum.to_list(0..11)
    end

    test "and does not fall over on a key that is not a number" do
      assert NestedParams.list(%{"b" => %{"n" => 2}, "0" => %{"n" => 0}, "a" => %{"n" => 1}})
             |> Enum.map(& &1["n"]) == [0, 1, 2]
    end

    test "passes rubbish through for the caller to judge" do
      # The whole reason this is not `Enum.filter(&is_map/1)`.
      assert NestedParams.list(%{"0" => "hello"}) == ["hello"]
      assert NestedParams.list(["hello"]) == ["hello"]
      assert NestedParams.list(nil) == []
    end
  end
end

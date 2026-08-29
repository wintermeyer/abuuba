defmodule Abuuba.Federation.BodyLimitTest do
  @moduledoc """
  A ceiling applied after the fact is not a ceiling.

  The federation client used to read a response whole and trim it afterwards,
  which meant a sender chose how much memory this server allocated. Verified
  against a real socket rather than only here: a server answering with 300 MB
  got 7 MB out before the connection dropped, where before the change it sent
  all 300 MB and every byte was accepted. What this file covers is the
  arithmetic that decides when to stop.
  """
  use ExUnit.Case, async: true

  alias Abuuba.Federation.HTTP.BodyLimit

  defp resp(body), do: {:req, %{body: body}}

  defp feed(collector, chunks) do
    Enum.reduce_while(chunks, resp(""), fn chunk, acc ->
      case collector.({:data, chunk}, acc) do
        {:cont, next} -> {:cont, next}
        {:halt, next} -> {:halt, next}
      end
    end)
  end

  test "keeps reading while there is room" do
    {_req, resp} = feed(BodyLimit.collect(100), ["one", "two"])

    assert resp.body == "onetwo"
  end

  test "stops at the ceiling and hands back exactly it" do
    {_req, resp} = feed(BodyLimit.collect(10), [String.duplicate("x", 50)])

    assert byte_size(resp.body) == 10
  end

  test "and stops part way through a stream rather than at the end of it" do
    # The point of the change: the decision is made on the chunk that crosses
    # the line, not after everything has arrived.
    collector = BodyLimit.collect(10)

    assert {:cont, acc} = collector.({:data, "12345"}, resp(""))
    assert {:halt, {_req, halted}} = collector.({:data, "678901234"}, acc)
    assert halted.body == "1234567890"
  end

  test "a body exactly at the ceiling is not read past" do
    assert {:halt, {_req, resp}} = BodyLimit.collect(4).({:data, "abcd"}, resp(""))

    assert resp.body == "abcd"
  end

  test "an empty body is nothing to stop for" do
    assert {:cont, {_req, resp}} = BodyLimit.collect(10).({:data, ""}, resp(""))

    assert resp.body == ""
  end
end

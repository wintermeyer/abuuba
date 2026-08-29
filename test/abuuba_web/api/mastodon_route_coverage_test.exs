defmodule AbuubaWeb.Api.MastodonRouteCoverageTest do
  @moduledoc """
  The README says every endpoint Mastodon declares under `/api/v1` and
  `/api/v2` is answered here. This is that sentence as a test. The fixture is
  Mastodon's route table, one `VERB /path` per line, and every line has to
  match one of our routes: a parameter segment of ours matches any segment of
  theirs, and `PUT` and `PATCH` stand in for each other, as they do in Rails.
  """
  use ExUnit.Case, async: true

  @fixture Path.expand("../../support/data/mastodon_api_routes.txt", __DIR__)
  @verbs %{
    "GET" => [:get],
    "POST" => [:post],
    "DELETE" => [:delete],
    "PUT" => [:put, :patch],
    "PATCH" => [:put, :patch]
  }

  test "every route of Mastodon's client API is answered" do
    ours = Enum.map(AbuubaWeb.Router.__routes__(), &{&1.verb, pattern(&1.path)})

    missing =
      @fixture
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.reject(&answered?(&1, ours))

    assert missing == [],
           "Mastodon routes without an answer here:\n" <> Enum.join(missing, "\n")
  end

  defp answered?(line, ours) do
    [verb, path] = String.split(line, " ", parts: 2)
    literal = String.replace(path, ~r/:[a-z_]+/, "x")
    verbs = Map.fetch!(@verbs, verb)
    Enum.any?(ours, fn {v, re} -> v in verbs and Regex.match?(re, literal) end)
  end

  defp pattern(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _ -> "[^/]+"
      "*" <> _ -> ".*"
      seg -> Regex.escape(seg)
    end)
    |> then(&Regex.compile!("^#{&1}$"))
  end
end

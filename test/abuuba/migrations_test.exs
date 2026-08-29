defmodule Abuuba.MigrationsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Reads the migration files rather than running them.

  A developer's database is built one migration at a time as they are written,
  so it never notices two of them creating the same table: the second one was
  added to a file that had already been applied. A fresh database sees both and
  stops on the first, which is why this was only ever visible in CI, where the
  database is empty every time.
  """

  # Read when the test runs rather than when it compiles. A module attribute
  # would freeze the list at compile time, and a migration added afterwards
  # would be checked by nothing until somebody happened to force a recompile.
  defp migrations, do: Path.wildcard("priv/repo/migrations/*.exs")

  test "there are migrations to check" do
    # Otherwise the two checks below pass by finding nothing, which is the one
    # way a guard can be worse than no guard.
    refute migrations() == []
  end

  test "no table is created twice" do
    # `create table(:x)` in two files is a fresh database failing on the second
    # one, however long both have been in the repository.
    duplicates =
      migrations()
      |> Enum.flat_map(&created_tables/1)
      |> duplicated()

    assert duplicates == [],
           "these tables are created by more than one migration: #{inspect(duplicates)}"
  end

  test "no index is created twice under the same name" do
    duplicates =
      migrations()
      |> Enum.flat_map(&created_indexes/1)
      |> duplicated()

    assert duplicates == [], "these indexes are created twice: #{inspect(duplicates)}"
  end

  defp created_tables(path) do
    path
    |> File.read!()
    |> then(&Regex.scan(~r/create table\(:([a-z_]+)/, &1))
    |> Enum.map(fn [_match, table] -> table end)
  end

  # Named indexes are compared by their name, and unnamed ones by the columns
  # Ecto would derive one from, which is the same thing Postgres will refuse.
  defp created_indexes(path) do
    source = File.read!(path)

    named =
      ~r/create (?:unique_)?index\(:([a-z_]+),.*?name: :([a-z_0-9]+)/s
      |> Regex.scan(source)
      |> Enum.map(fn [_match, table, name] -> "#{table}:#{name}" end)

    unnamed =
      ~r/create (?:unique_)?index\(:([a-z_]+), \[([^\]]*)\]\)/
      |> Regex.scan(source)
      |> Enum.map(fn [_match, table, columns] ->
        "#{table}:#{String.replace(columns, ~r/\s/, "")}"
      end)

    named ++ unnamed
  end

  defp duplicated(names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end

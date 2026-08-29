defmodule Abuuba.Importer.Source do
  @moduledoc """
  Reading the database being taken over.

  Every step needs the same three things: the repo to ask (a second connection
  to somebody else's server, or this one with a table prefix in a test), the
  name of a source table, and rows in a shape that does not depend on the order
  that server happens to declare its columns in.

  Kept here rather than in whichever step needed it first, so that the prefix
  and the repo option have one definition. Steps arrive one issue at a time and
  each copy of this would be a place the convention could quietly drift.
  """

  @doc """
  A column that means nothing when it is empty.

  The source writes an absent string as `''` about as often as it writes null,
  and the two mean the same thing everywhere in this import.
  """
  @spec presence(term()) :: term() | nil
  def presence(nil), do: nil
  def presence(""), do: nil
  def presence(value), do: value

  @doc """
  A time from the source, as a `DateTime`.

  Stored without a zone over there, in UTC, which is what Rails does and what
  every one of these columns means. A string is accepted because a computed
  column or a cast can hand one back, and reading that as "no time" would be a
  silent loss rather than an error.
  """
  @spec at(term()) :: DateTime.t() | nil
  def at(%DateTime{} = at), do: at
  def at(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  def at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _not_a_time -> nil
    end
  end

  def at(_missing), do: nil

  @doc """
  How many rows a table has, for a report or a check.
  """
  @spec count(keyword(), String.t(), String.t()) :: integer()
  def count(opts, table, where \\ "true") do
    case query(opts, "SELECT count(*) FROM #{table(opts, table)} WHERE #{where}") do
      {:ok, %{rows: [[count]]}} -> count
      _unreadable -> 0
    end
  end

  @doc """
  A table name, with the prefix a test uses to point the import at tables in
  its own database. Empty against a real instance.
  """
  @spec table(keyword(), String.t()) :: String.t()
  def table(opts, name), do: "#{Keyword.get(opts, :prefix, "")}#{name}"

  @doc """
  Runs a query against the source, turning a raised database error into a
  value. A step reports "the source could not be read"; it does not crash
  halfway through a takeover.
  """
  @spec query(keyword(), String.t(), list()) :: {:ok, map()} | {:error, term()}
  def query(opts, sql, params \\ []) do
    repo = Keyword.get(opts, :repo, Abuuba.Repo)

    repo.query(sql, params)
  rescue
    error -> {:error, error}
  end

  @doc """
  The same, with rows as maps keyed by column name.

  Reading by position would make an import depend on the order the source
  declares its columns in, which is exactly the kind of dependency that breaks
  without saying anything.
  """
  @spec rows(keyword(), String.t(), list()) :: {:ok, [map()]} | {:error, term()}
  def rows(opts, sql, params \\ []) do
    case query(opts, sql, params) do
      {:ok, %{columns: columns, rows: rows}} ->
        {:ok, Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

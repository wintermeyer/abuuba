defmodule AbuubaWeb.Params do
  @moduledoc """
  Turning what a browser sent into something safe to look up.

  Every screen that answers `phx-value-id` had its own copy of this, and the
  copies did not agree: four modules defined a private `numeric/1` and three a
  private `to_integer/1`, in two spellings with opposite strictness, so which
  one a reader was looking at depended on which file they had open.

  The two here are deliberately different from each other, and the names say
  which is which rather than leaving it to be read out of the bodies.
  """

  # Postgres `bigint`. A larger number is not a row that is missing, it is a
  # value the column cannot hold, and handing it to Ecto raises instead of
  # answering nothing.
  @max_id 9_223_372_036_854_775_807

  @doc """
  A database id, or `nil`.

  Strict on purpose. The whole string has to be the number, so `"12abc"` is a
  miss rather than row twelve, and it has to fit in a `bigint`, because an id
  past that range reaches the database as an error rather than as a lookup
  that finds nothing. Negative is refused for the same reason it is never
  minted.

  `nil` for anything else, which callers read as "no such row" — the same
  answer they would get for an id that simply is not there.
  """
  @spec id(term()) :: {:ok, non_neg_integer()} | nil
  def id(value) when is_integer(value) and value >= 0 and value <= @max_id, do: {:ok, value}

  def id(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 and number <= @max_id -> {:ok, number}
      _not_an_id -> nil
    end
  end

  def id(_value), do: nil

  @doc """
  A whole number from a form field, falling back to zero.

  Lenient on purpose, and not for ids: this reads the counters and offsets a
  form sends, where a trailing unit or an empty box should mean zero rather
  than an error on screen. Use `id/1` for anything that becomes a row.
  """
  @spec to_integer(term()) :: integer()
  def to_integer(value) when is_integer(value), do: value

  def to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  def to_integer(_value), do: 0
end

defmodule AbuubaWeb.Params do
  @moduledoc """
  Turning what a browser sent into something safe to look up.

  Three modules had their own private `to_integer/1` for reading a form field,
  in one spelling, so this is where that lives now.

  There is deliberately no `id/1` here. Ids go through
  `Abuuba.Snowflake.cast/1`, which is the id type itself and is stricter than
  anything worth writing twice: it takes only the canonical spelling, so one
  row cannot be addressed by `"7"`, `"+7"` and `"007"` alike when clients treat
  those strings as cache keys; it bounds the value to what a `bigint` column
  can hold, so a huge id in a URL is a miss rather than a Postgrex encode
  error; and it keeps the reserved negative range reachable from our own code
  for the actors abuuba creates for itself.
  """

  @doc """
  A whole number from a form field, falling back to zero.

  Lenient on purpose, and not for ids: this reads the counters and offsets a
  form sends, where a trailing unit or an empty box should mean zero rather
  than an error on screen. Use `Abuuba.Snowflake.cast/1` for anything that
  becomes a row.
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

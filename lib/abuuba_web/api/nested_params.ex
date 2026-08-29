defmodule AbuubaWeb.API.NestedParams do
  @moduledoc """
  The two spellings a client uses for a list of sub-objects, read as one.

  `media_attributes[][id]=1` arrives as a list. `media_attributes[0][id]=1`
  arrives as a map keyed by the index, because that is what Phoenix makes of a
  numbered bracket and what every HTML form and most HTTP libraries produce.
  The upstream API documentation uses the numbered form, and the parameter
  names themselves (`_attributes`) come from a convention where numbering is
  the normal way to write it, so it is the commoner of the two.

  Three places had grown their own version of this and a fourth had none:
  filters read only the list, so the documented call to add a keyword answered
  "keyword can't be blank" for a keyword that was plainly there, and saved a
  rule with nothing to look for. The two that did read both sorted the index
  as a string, which puts "10" before "2".
  """

  @doc """
  The entries as a list, whichever of the two shapes the client sent.

  Reshaping only. What an entry has to look like is the caller's business, and
  the three callers genuinely disagree: a bad profile field is refused, a bad
  media id is skipped so a client with a stale id does not lose its edit. A
  helper that dropped everything unrecognisable would have turned the first of
  those into a 200 that quietly emptied somebody's profile links.
  """
  @spec list(term()) :: list()
  def list(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.sort_by(fn {index, _value} -> order(index) end)
    |> Enum.map(fn {_index, value} -> value end)
  end

  def list(value), do: List.wrap(value)

  # Numbered keys sort as numbers, so the tenth entry is not the third.
  # Anything else sorts after them, in its own order, so a key that is not a
  # number cannot make the sort raise.
  defp order(index) do
    case index |> to_string() |> Integer.parse() do
      {number, ""} -> {0, number, ""}
      _ -> {1, 0, to_string(index)}
    end
  end
end

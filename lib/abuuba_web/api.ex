defmodule AbuubaWeb.API do
  @moduledoc """
  What every Mastodon-compatible endpoint shares.

  Most of what is here looks like something worth improving, and none of it is.
  Existing clients were written against the reference implementation's exact
  behaviour, including the parts of it that read as mistakes, and an app that
  works against Mastodon has to work against abuuba without knowing which it is
  talking to. So the rule for this module is narrow: match the behaviour, and
  write down why each quirk is load-bearing so that nobody tidies it up later.

  ## Ids are strings

  Every id in every response body is a string, never a number. They are 64-bit
  snowflakes, and a JavaScript client parsing one as a number silently loses
  the low bits past 2^53, so two different posts start comparing equal. The
  reference implementation made them strings for exactly this reason and every
  client now expects that shape.

  ## Errors are one shape

  `{"error": "..."}`, whatever went wrong. Clients match on the key.
  """

  import Plug.Conn

  alias Abuuba.Snowflake
  alias AbuubaWeb.API.NestedParams

  @doc """
  An id, as it goes on the wire.
  """
  @spec id(integer() | String.t() | nil) :: String.t() | nil
  def id(nil), do: nil
  def id(value) when is_integer(value), do: Integer.to_string(value)
  def id(value) when is_binary(value), do: value

  @doc """
  Answers with the one error shape every client matches on.
  """
  @spec error(Plug.Conn.t(), atom() | integer(), String.t(), map() | nil) :: Plug.Conn.t()
  def error(conn, status, message, details \\ nil) do
    body = %{error: message}

    conn
    |> put_status(status)
    |> Phoenix.Controller.json(
      if details in [nil, %{}], do: body, else: Map.put(body, :details, details)
    )
    |> halt()
  end

  @doc """
  An id from a query parameter, or `nil`.

  A parameter that is not an id is treated as absent rather than as an error.
  Clients send `max_id=` with nothing after it often enough that refusing would
  break paging for them, and the reference implementation ignores it.
  """
  @spec id_param(map(), String.t()) :: integer() | nil
  def id_param(params, key), do: params |> Map.get(key) |> parse_id()

  @doc """
  Whether a query parameter means yes.

  A flag arrives as a string from a query string and as a boolean from a JSON
  body, and clients send `1` for both. Anything else is no, including the
  absent one.
  """
  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value in [true, "true", "1", 1]

  @doc """
  An id a caller already holds, or `nil` where it is not one.

  Ids arrive as strings in this API, so every route that takes one has to
  answer the same question. Public rather than private so that a caller with
  the value in hand does not have to build a map to ask it.
  """
  @spec parse_id(term()) :: integer() | nil
  def parse_id(value) when is_integer(value), do: value

  def parse_id(value) when is_binary(value) do
    case Snowflake.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  def parse_id(_value), do: nil

  @doc """
  The ids in an `id[]` parameter, in the order they were sent.

  Anything that is not an id is dropped rather than refused, and duplicates
  collapse. A client holding one stale id wants the rest of its page, and asking
  twice for the same account is a request for it once.
  """
  @spec id_list(map(), String.t()) :: [integer()]
  def id_list(params, key) do
    params
    |> Map.get(key, [])
    |> NestedParams.list()
    |> Enum.map(&parse_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  A boolean parameter, read the way the reference implementation reads one.

  Everything is true except an explicit falsehood. That is Rails' rule rather
  than a strict one, and it has to be matched: a client sending `whole_word=on`
  from a checkbox means yes, and a stricter reading would silently store the
  opposite of what somebody ticked.
  """
  @spec boolean(term(), boolean()) :: boolean()
  def boolean(value, default \\ false)
  def boolean(nil, default), do: default
  def boolean(value, _default) when is_boolean(value), do: value
  def boolean(value, _default) when value in [0, "0"], do: false

  # The reference implementation's exact set, `no` deliberately absent from it:
  # a stricter or a wider list is a parameter that means one thing there and
  # another here.
  def boolean(value, _default) when is_binary(value) do
    String.downcase(value) not in ["f", "false", "off", "0", ""]
  end

  def boolean(_value, _default), do: true

  @doc """
  How many records a request asked for, bounded.

      limit(params, 20, 40)

  Negative and absurd values are clamped rather than refused, which is what the
  reference implementation does: `limit=-1` is a client bug, and answering it
  with a page is friendlier than answering it with an error nobody handles.
  `limit=0` is left alone at zero, so a client that asks for an empty page gets
  one rather than a single record it did not want.
  """
  @spec limit(map(), pos_integer(), pos_integer() | nil) :: pos_integer()
  def limit(params, default, max \\ nil) do
    max = max || default * 2

    case Map.get(params, "limit") do
      nil -> default
      value -> value |> to_integer(default) |> abs() |> min(max)
    end
  end

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> default
    end
  end

  defp to_integer(value, _default) when is_integer(value), do: value
  defp to_integer(_value, default), do: default
end

defmodule Abuuba.OAuth.Scopes do
  @moduledoc """
  The scope tree, and what counts as covering what.

  Scopes are hierarchical: `read` covers `read:statuses`, and `admin:read`
  covers `admin:read:accounts`. A token asking for `read:statuses` is satisfied
  by a token holding `read`, and that direction only. Getting this backwards
  would let a narrow token reach a broad endpoint, which is the whole point of
  asking for narrow scopes in the first place.

  The set is Mastodon's, verbatim, because a client asks for the scopes it was
  written against and gets refused outright if the server does not know one of
  them. A scope we do not recognise is rejected rather than ignored: silently
  dropping it would hand back a token that does less than the client was told,
  and the failure would surface much later as an unexplained 403.
  """

  @top_level ~w(read write follow push profile)

  @read_children ~w(
    accounts blocks bookmarks favourites filters follows lists mutes
    notifications search statuses
  )

  @write_children ~w(
    accounts blocks bookmarks conversations favourites filters follows lists
    media mutes notifications reports statuses
  )

  @admin_read_children ~w(accounts reports domain_allows domain_blocks ip_blocks email_domain_blocks canonical_email_blocks)
  @admin_write_children @admin_read_children

  @doc """
  Every scope this server understands.
  """
  @spec known() :: [String.t()]
  def known do
    @top_level ++
      Enum.map(@read_children, &"read:#{&1}") ++
      Enum.map(@write_children, &"write:#{&1}") ++
      ["admin:read", "admin:write"] ++
      Enum.map(@admin_read_children, &"admin:read:#{&1}") ++
      Enum.map(@admin_write_children, &"admin:write:#{&1}")
  end

  @doc """
  Whether a scope is one we understand.
  """
  @spec known?(String.t()) :: boolean()
  def known?(scope), do: scope in known()

  @doc """
  Parses a space-separated scope string.

  Returns `{:error, unknown}` naming every scope we do not recognise, so the
  client is told what to fix rather than just that something was wrong.
  """
  @spec parse(String.t() | nil) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def parse(nil), do: {:ok, ["read"]}
  def parse(""), do: {:ok, ["read"]}

  def parse(scopes) when is_binary(scopes) do
    requested =
      scopes
      |> String.split([" ", "+"], trim: true)
      |> Enum.uniq()

    case Enum.reject(requested, &known?/1) do
      [] -> {:ok, requested}
      unknown -> {:error, unknown}
    end
  end

  @doc """
  Whether `held` is enough for `required`.

  A held scope covers a required one when they are equal, or when the held one
  is an ancestor of it. `read` covers `read:statuses`; `read:statuses` does not
  cover `read`.
  """
  @spec covers?([String.t()] | String.t(), String.t()) :: boolean()
  def covers?(held, required) when is_binary(held), do: covers?(parse!(held), required)

  def covers?(held, required) when is_list(held) do
    Enum.any?(held, &covers_one?(&1, required))
  end

  defp covers_one?(held, required) do
    held == required or String.starts_with?(required, held <> ":")
  end

  @doc """
  Whether a set of scopes covers every one of a set of requirements.
  """
  @spec covers_all?([String.t()] | String.t(), [String.t()]) :: boolean()
  def covers_all?(held, required) when is_list(required) do
    Enum.all?(required, &covers?(held, &1))
  end

  @doc """
  Narrows a request to what the application is allowed to ask for.

  An app registered for `read` must not be able to obtain `write` by asking for
  it at the authorize step; the registration is the ceiling.
  """
  @spec narrow([String.t()], [String.t()] | String.t()) :: [String.t()]
  def narrow(requested, allowed) when is_binary(allowed), do: narrow(requested, parse!(allowed))

  def narrow(requested, allowed) do
    Enum.filter(requested, &covers?(allowed, &1))
  end

  @doc """
  The canonical string form: sorted, space separated.

  Sorted so that two requests for the same scopes in different orders are the
  same token, which is what makes the one-live-token-per-app-and-scope index do
  what it is meant to.
  """
  @spec to_string([String.t()]) :: String.t()
  def to_string(scopes) when is_list(scopes), do: scopes |> Enum.sort() |> Enum.join(" ")

  @doc """
  Parses, raising on anything unknown. For scopes that came from our own
  database rather than from a client.
  """
  @spec parse!(String.t() | nil) :: [String.t()]
  def parse!(scopes) do
    case parse(scopes) do
      {:ok, parsed} -> parsed
      {:error, unknown} -> raise ArgumentError, "unknown scopes: #{inspect(unknown)}"
    end
  end
end

defmodule Abuuba.Federation.DoubleKnock do
  @moduledoc """
  Delivering to a peer whose signature scheme we do not know.

  The fediverse is mid-migration: older servers understand only draft-cavage,
  newer ones only RFC 9421, and there is no way to ask which. So we knock
  twice. The first attempt is cavage, because that is still what most of the
  network speaks; a 400 or a 401 is read as "wrong scheme" and the request is
  sent again signed the RFC 9421 way.

  Only those two statuses trigger the retry. A 404 means the inbox is gone, a
  410 means the actor is, and a 500 means their server is broken; re-signing
  and sending again would just be a second failure and, for a 500, a second
  load on something already struggling.

  What worked is worth remembering, so `deliver/2` reports which scheme was
  used along with the peer's own status. The delivery pipeline can cache the
  scheme per host and skip the wasted first knock next time, and it decides for
  itself what a given status means for retries: flattening a 401 into an error
  of our own would throw away exactly what that decision needs.
  """

  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.Signature.RFC9421

  @retry_statuses [400, 401]

  @doc """
  Delivers a signed request, retrying with the other signature scheme if the
  peer rejects the first.

  `send` is given `{url, headers, body}` and returns `{:ok, status}` or
  `{:error, reason}`. It is passed in rather than called directly so that this
  logic is testable without a network, and so the outbound HTTP layer keeps its
  own anti-SSRF rules in one place.

  Pass `prefer: :rfc9421` to skip straight to the newer scheme for a host
  already known to want it.
  """
  @spec deliver(keyword(), (String.t(), list(), binary() -> {:ok, integer()} | {:error, term()})) ::
          {:ok, %{status: integer(), scheme: :cavage | :rfc9421}}
          | {:error, term()}
  def deliver(opts, send) do
    order =
      case Keyword.get(opts, :prefer, :cavage) do
        :rfc9421 -> [:rfc9421, :cavage]
        _ -> [:cavage, :rfc9421]
      end

    attempt(order, opts, send)
  end

  # Unreachable while both schemes are in the list, because the last attempt
  # returns its status rather than recursing. Kept so that a future third
  # scheme cannot silently fall off the end.
  defp attempt([], _opts, _send), do: {:error, :no_signature_scheme}

  defp attempt([scheme | rest], opts, send) do
    with {:ok, headers} <- sign(scheme, opts) do
      url = Keyword.fetch!(opts, :url)
      body = Keyword.get(opts, :body, "")

      case send.(url, headers ++ Keyword.get(opts, :headers, []), body) do
        {:ok, status} when status in @retry_statuses and rest != [] ->
          attempt(rest, opts, send)

        {:ok, status} ->
          {:ok, %{status: status, scheme: scheme}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp sign(:cavage, opts), do: Signature.sign(opts)
  defp sign(:rfc9421, opts), do: RFC9421.sign(opts)
end

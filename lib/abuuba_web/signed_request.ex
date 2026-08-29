defmodule AbuubaWeb.SignedRequest do
  @moduledoc """
  Establishing which server sent an inbound request.

  There is no transport-level identity on the fediverse: TLS says the
  connection reached the host it claimed, not that the request came from the
  actor it names. The HTTP signature is the only thing that does, so anything
  that has to know who is asking goes through here rather than reading a header
  and hoping.

  Used by the inbox, which will not accept an activity from an unidentified
  sender, and by the followers-synchronisation collection, which will not tell
  a stranger who follows an account here.
  """

  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs

  @doc """
  Verifies the signature on a request and returns the key that signed it.

  `body` is the bytes that arrived, which is what the signature covers; a
  re-encoding of the parsed JSON is not those bytes, and key order alone would
  break it. A GET has none, and signs `host` instead of `digest`.
  """
  @spec verify(Plug.Conn.t(), binary() | nil) :: {:ok, String.t()} | {:error, atom()}
  def verify(conn, body \\ nil) do
    Signature.verify(
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      host: conn.host,
      headers: signed_headers(conn),
      body: body,
      resolve_key: &resolve_key/1
    )
  end

  @doc """
  The actor URI behind a verified key.
  """
  @spec signer(String.t()) :: String.t()
  def signer(key_id), do: Signature.actor_uri_from_key_id(key_id)

  @doc """
  Notes that the server behind a verified key is alive.

  A request we could verify is proof that the server sending it is running,
  whatever our own outbound attempts to it concluded. That matters more than it
  sounds: a domain we have given up on is skipped entirely, so without this it
  would take a manual intervention to start delivering to it again.

  Separate from `signer/1` rather than folded into it, because it is a write.
  A caller that only wants to know who signed something should not be marking
  domains alive as a side effect of asking.
  """
  @spec record_alive(String.t()) :: :ok
  def record_alive(key_id) do
    key_id |> signer() |> URIs.host_of() |> Availability.record_success()
  end

  # `host` is one of the signed headers, and Plug lifts it out of the header
  # list onto the connection. Verifying against the header list alone would
  # therefore build the signing string with an empty host and reject every
  # legitimately signed request.
  defp signed_headers(conn) do
    if List.keymember?(conn.req_headers, "host", 0) do
      conn.req_headers
    else
      [{"host", host_with_port(conn)} | conn.req_headers]
    end
  end

  defp host_with_port(%{host: host, port: port, scheme: scheme}) do
    if default_port?(scheme, port), do: host, else: "#{host}:#{port}"
  end

  defp default_port?(:https, 443), do: true
  defp default_port?(:http, 80), do: true
  defp default_port?(_scheme, _port), do: false

  # Local first, then fetch. A peer we have never met signs its very first
  # delivery with a key we do not hold yet, so refusing to go and look would
  # mean never being able to receive a first follow.
  defp resolve_key(key_id) do
    case Signature.local_key_resolver().(key_id) do
      {:ok, pem} ->
        {:ok, pem}

      :error ->
        # By the key, not by a uri derived from it. Cutting the id at `#` is
        # right for most of the network and wrong for the rest, and resolving
        # the key's own URL as an actor cannot work either: a server that
        # serves a stub there serves one with no inbox, which is refused as an
        # actor and rightly so. `resolve_key_owner/2` asks the key whose it is.
        #
        # And the account it returns is used directly. Deriving one back out of
        # the key id would ask the same question that failed a line ago.
        with {:ok, account} <- ResolveActor.resolve_key_owner(key_id) do
          Signature.public_key_of(account)
        end
    end
  end
end

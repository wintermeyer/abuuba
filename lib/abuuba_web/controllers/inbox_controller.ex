defmodule AbuubaWeb.InboxController do
  @moduledoc """
  Where other servers deliver.

  The response is 202 and nothing else. A sender is holding a socket open, and
  doing the work inline means resolving actors and threads, which means
  requests of our own to servers that may be slow or down. That would make our
  inbox as slow as the slowest server we depend on, and a sender that times out
  retries, which makes it worse. So the request is verified, queued, and
  answered.

  A shared inbox and a per-actor inbox do the same thing here. Which one a peer
  used says something about how they batched delivery and nothing about what
  the activity means, and the audience inside the activity is what decides who
  it reaches.
  """

  use AbuubaWeb, :controller

  require Logger

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.FollowerSyncWorker
  alias Abuuba.Federation.Inbox
  alias Abuuba.Federation.IngressWorker
  alias Abuuba.Federation.JSONLD
  alias Abuuba.Federation.Limits
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs
  alias AbuubaWeb.SignedRequest

  # An activity is a few kilobytes. Anything past a megabyte is not a post.
  @max_body_bytes Limits.max_document_bytes()

  def create(conn, _params) do
    with {:ok, body, conn} <- raw_body(conn),
         {:ok, activity} <- decode(body),
         {:ok, key_id} <- SignedRequest.verify(conn, body),
         :ok <- check_actor_matches_signature(activity, key_id),
         :ok <- check_domain_accepted(key_id) do
      accept(conn, activity, key_id)
    else
      {:error, reason} ->
        note(conn, reason)
        refuse(conn, reason)
    end
  end

  # The reason, in the log, once.
  #
  # Nine different failures leave by the same door with the same sentence --
  # "Signature could not be verified" -- and nothing anywhere said which. A
  # peer whose deliveries abuuba refuses gets a 401 it cannot act on, and the
  # operator reading the log afterwards sees only that one was sent. Chasing a
  # real refusal from GoToSocial meant instrumenting this before the question
  # could even be asked.
  #
  # The signer is named where it is known, because "somebody's signature did
  # not verify" and "gotosocial.interop's did" are different problems.
  defp note(conn, reason) do
    Logger.warning(fn ->
      signer =
        conn
        |> get_req_header("signature")
        |> List.first()
        |> key_id_of()

      "refused a delivery from #{signer}: #{inspect(reason)}"
    end)
  end

  defp key_id_of(nil), do: "an unsigned request"

  defp key_id_of(signature) do
    case Regex.run(~r/keyId="([^"]+)"/, signature) do
      [_match, key_id] -> key_id
      _no_key_id -> "a request whose signature names no key"
    end
  end

  # Queued rather than done, and answered before the queue is even read.
  #
  # This is also where a domain we had given up on delivering to comes back: it
  # is talking to us and the signature checked out, so whatever our outbound
  # attempts concluded was wrong, or is no longer true.
  defp accept(conn, activity, key_id) do
    SignedRequest.record_alive(key_id)

    signer = SignedRequest.signer(key_id)
    check_follower_synchronisation(conn, signer)

    {:ok, _job} = IngressWorker.enqueue(activity, signer)

    send_resp(conn, :accepted, "")
  end

  # FEP-8fcf, the receiving half. The sender has attached a digest of the
  # accounts here it believes follow it; when ours disagrees, a repair is
  # queued. Read off a verified request, so the header can only ever speak for
  # the account that signed it.
  #
  # Nothing here fails the delivery. A malformed or unwelcome header is a
  # question about a follower list, and refusing the activity over it would
  # drop somebody's post for a reason that has nothing to do with the post.
  defp check_follower_synchronisation(conn, signer) do
    with [raw | _rest] <- get_req_header(conn, "collection-synchronization"),
         %Account{} = account <- Accounts.get_account_by_uri(signer) do
      FollowerSyncWorker.enqueue(account, raw)
    else
      _ -> :ok
    end
  end

  # The bytes that arrived, which is what the signature covers; a re-encoding of
  # the parsed JSON is not those bytes, and key order alone would break it.
  #
  # Two ways in, because `application/activity+json` is not
  # `application/json`: Plug.Parsers passes it through unread, so the body is
  # usually still there to be read. Where something upstream did consume it,
  # AbuubaWeb.Plugs.CacheBodyReader has stashed it.
  defp raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) -> within_limit(body, conn)
      nil -> read_raw_body(conn)
    end
  end

  defp read_raw_body(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> within_limit(body, conn)
      {:more, _partial, _conn} -> {:error, :too_large}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp within_limit(body, _conn) when byte_size(body) > @max_body_bytes, do: {:error, :too_large}
  defp within_limit(body, conn), do: {:ok, body, conn}

  # Refused rather than read past, when a document uses a JSON-LD construction
  # that plain map access would misread. See `Abuuba.Federation.JSONLD`: acting
  # on the part of such a document we can see is worse than not acting at all,
  # because the sender chooses which part that is.
  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = activity} -> readable(activity)
      _ -> {:error, :malformed}
    end
  end

  # The signature says who sent the request. The activity says who did the
  # thing. A request signed by one actor carrying an activity attributed to
  # another is somebody speaking for somebody else, which is the forgery this
  # check exists for. The exception is a Delete of the actor itself, which a
  # server sometimes signs with its own key as the actor is being torn down.
  defp check_actor_matches_signature(activity, key_id) do
    signer = Signature.actor_uri_from_key_id(key_id)
    claimed = Inbox.actor_uri(activity)

    cond do
      is_nil(claimed) -> {:error, :actor_missing}
      URIs.same_host?(signer, claimed) -> :ok
      true -> {:error, :actor_mismatch}
    end
  end

  # Refused here rather than in the worker. Queueing it would mean resolving
  # the actor, which is a request to the very server a suspension says not to
  # talk to.
  defp check_domain_accepted(key_id) do
    if key_id |> Signature.actor_uri_from_key_id() |> Inbox.acceptable_actor?() do
      :ok
    else
      {:error, :domain_refused}
    end
  end

  defp readable(activity) do
    if JSONLD.foreign_shape?(activity), do: {:error, :unreadable_shape}, else: {:ok, activity}
  end

  defp refuse(conn, :unreadable_shape) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "That document uses JSON-LD constructions this server does not read"})
  end

  defp refuse(conn, :too_large) do
    conn |> put_status(:request_entity_too_large) |> json(%{error: "Activity too large"})
  end

  # A digest mismatch belongs here rather than with the malformed bodies: the
  # body did not match what was signed, which is a failed authentication of the
  # request and not a badly written one.
  defp refuse(conn, reason)
       when reason in [
              :unknown_key,
              :bad_signature,
              :missing_signature,
              :malformed_signature,
              :digest_mismatch,
              :missing_digest,
              :missing_host,
              :missing_date,
              :unsupported_algorithm
            ] do
    conn |> put_status(:unauthorized) |> json(%{error: "Signature could not be verified"})
  end

  # 403 rather than 202-and-discard: a server whose activities we refuse should
  # be able to find that out, and a silent accept teaches its retry logic that
  # everything arrived.
  defp refuse(conn, :domain_refused) do
    conn |> put_status(:forbidden) |> json(%{error: "This server does not federate with yours"})
  end

  defp refuse(conn, reason) when reason in [:actor_mismatch, :actor_missing] do
    conn |> put_status(:forbidden) |> json(%{error: "Actor does not match the signature"})
  end

  defp refuse(conn, :stale_request) do
    conn |> put_status(:unauthorized) |> json(%{error: "Request is outside the accepted window"})
  end

  # A peer we could not reach to check a key is our problem rather than theirs,
  # and 503 is the status that says "try again" instead of "do not bother".
  defp refuse(conn, reason) when reason in [:timeout, :circuit_open, :econnrefused] do
    conn |> put_status(:service_unavailable) |> json(%{error: "Could not verify right now"})
  end

  defp refuse(conn, _reason) do
    conn |> put_status(:bad_request) |> json(%{error: "Activity could not be read"})
  end
end

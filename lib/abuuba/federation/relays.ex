defmodule Abuuba.Federation.Relays do
  @moduledoc """
  Subscribing to relays, so that a small server sees more than its own corner.

  A relay forwards every public post it is sent on to everybody subscribed to
  it. For a new instance with three accounts and no follows that is the
  difference between an empty federated timeline and a populated one, which is
  why turning one on is usually the first thing an admin does.

  ## How a subscription is made

  By following the public collection rather than an actor: there is nobody
  there to follow. The relay answers with an `Accept` naming the `Follow` we
  sent, and that name is the only thing tying the answer back to the request,
  so it is stored.

  Nothing is forwarded while the subscription is pending. Sending posts to a
  server that has not yet said it wants them is how a relay operator ends up
  with traffic they never agreed to.

  ## What is forwarded

  Public statuses only. A relay redistributes to strangers, which is precisely
  what a status that is not public has asked us not to do. Unlisted is included
  in that exclusion: unlisted means "not in discovery surfaces", and a relay is
  the largest discovery surface there is.
  """

  import Ecto.Query

  alias Abuuba.Federation.Delivery
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Federation.JSONLD
  alias Abuuba.Federation.Relay
  alias Abuuba.Federation.URIs
  alias Abuuba.Repo
  alias Abuuba.Snowflake

  @public JSONLD.public()
  @context "https://www.w3.org/ns/activitystreams"

  @doc """
  Every relay this server knows about, whatever state it is in.
  """
  @spec list() :: [Relay.t()]
  def list, do: Relay |> order_by([r], asc: r.id) |> Repo.all()

  @doc """
  Registers a relay, switched off.

  Adding and enabling are separate so that a mistyped address can be corrected
  before anything is sent to it.
  """
  @spec add(String.t()) :: {:ok, Relay.t()} | {:error, Ecto.Changeset.t()}
  def add(inbox_url) do
    %Relay{} |> Relay.changeset(%{inbox_url: inbox_url}) |> Repo.insert()
  end

  @doc """
  Asks a relay to start forwarding to us.
  """
  @spec enable(Relay.t()) :: {:ok, Relay.t()} | {:error, Ecto.Changeset.t()}
  def enable(%Relay{} = relay) do
    follow_id = "#{URIs.base_url()}/activities/#{Snowflake.generate()}"

    with {:ok, relay} <-
           save(relay, %{state: :pending, follow_activity_id: follow_id}) do
      deliver(relay, follow_activity(follow_id))

      {:ok, relay}
    end
  end

  @doc """
  Asks a relay to stop, and stops forwarding to it immediately.

  The `Undo` is sent on a best-effort basis; the local state does not wait for
  it, because a relay that has gone away must not be able to keep us
  subscribed by never answering.
  """
  @spec disable(Relay.t()) :: {:ok, Relay.t()} | {:error, Ecto.Changeset.t()}
  def disable(%Relay{follow_activity_id: nil} = relay), do: save(relay, %{state: :idle})

  def disable(%Relay{} = relay) do
    follow_id = relay.follow_activity_id

    with {:ok, updated} <- save(relay, %{state: :idle, follow_activity_id: nil}) do
      deliver(relay, undo_activity(follow_id))

      {:ok, updated}
    end
  end

  @doc """
  Forgets a relay entirely, unsubscribing first where it was subscribed.
  """
  @spec remove(Relay.t()) :: {:ok, Relay.t()} | {:error, Ecto.Changeset.t()}
  def remove(%Relay{} = relay) do
    with {:ok, relay} <- disable(relay) do
      Repo.delete(relay)
    end
  end

  @doc """
  Records a relay's answer to the `Follow` with this id.

  `signer_uri` is whoever signed the request the answer arrived in, and it has
  to be on the same host as the relay's inbox. Without that check any server
  could subscribe us to a relay by naming a `Follow` id, and a relay's `Follow`
  id is not a secret: the relay itself has it.

  Returns `:error` for an id we never sent, which is the ordinary case for
  every `Accept` that belongs to an account follow rather than to a relay.
  """
  @spec accept(String.t() | nil, String.t() | nil) ::
          {:ok, Relay.t()} | {:error, :wrong_host} | :error
  def accept(follow_activity_id, signer_uri),
    do: answer(follow_activity_id, :accepted, signer_uri)

  @doc """
  Records that a relay refused us.
  """
  @spec reject(String.t() | nil, String.t() | nil) ::
          {:ok, Relay.t()} | {:error, :wrong_host} | :error
  def reject(follow_activity_id, signer_uri),
    do: answer(follow_activity_id, :rejected, signer_uri)

  @doc """
  The inboxes of every relay that agreed.

  Whether a relay's server is one we have given up on is not asked here:
  `Abuuba.Federation.Delivery` drops unreachable domains from the final inbox
  list, so a relay is skipped for the same reason and by the same rule as
  anybody else.
  """
  @spec inboxes() :: [String.t()]
  def inboxes do
    Relay
    |> where([r], r.state == :accepted)
    |> order_by([r], asc: r.id)
    |> select([r], r.inbox_url)
    |> Repo.all()
  end

  defp answer(follow_activity_id, _state, _signer) when not is_binary(follow_activity_id),
    do: :error

  defp answer(follow_activity_id, state, signer_uri) do
    case Repo.get_by(Relay, follow_activity_id: follow_activity_id) do
      nil -> :error
      relay -> answer_from(relay, state, signer_uri)
    end
  end

  # A relay's `Follow` id is not a secret, so the answer has to come from the
  # relay's own server. Refusing is `{:error, :wrong_host}` rather than the
  # `:error` that means "not a relay of ours at all": a caller that treats the
  # two alike would hand a forged relay answer on to whatever handles ordinary
  # follows.
  defp answer_from(relay, state, signer_uri) do
    if URIs.same_host?(relay.inbox_url, signer_uri) do
      save(relay, %{state: state})
    else
      {:error, :wrong_host}
    end
  end

  defp save(relay, attrs), do: relay |> Relay.changeset(attrs) |> Repo.update()

  defp follow_activity(follow_id) do
    %{
      "@context" => @context,
      "id" => follow_id,
      "type" => "Follow",
      "actor" => actor_uri(),
      "object" => @public
    }
  end

  defp undo_activity(follow_id) do
    %{
      "@context" => @context,
      "id" => follow_id <> "#undo",
      "type" => "Undo",
      "actor" => actor_uri(),
      "object" => follow_activity(follow_id)
    }
  end

  # Signed as the server, not as a person. There is no person involved in a
  # relay subscription, and signing as one would tell the relay which of our
  # accounts happened to trigger it.
  defp deliver(%Relay{inbox_url: inbox}, activity) do
    Delivery.deliver_to([inbox], activity, InstanceActor.fetch!())
  end

  defp actor_uri, do: InstanceActor.fetch!().uri

  @doc """
  Records that a delivery to a relay failed.

  The admin's own account of why, next to the state. A relay failing quietly
  looks exactly like a relay nobody has posted to yet, and what to do about it
  is different in each case.
  """
  @spec record_failure(String.t(), term()) :: :ok
  def record_failure(inbox_url, reason) do
    Relay
    |> where([r], r.inbox_url == ^inbox_url)
    |> Repo.update_all(
      set: [
        last_error: reason |> inspect() |> String.slice(0, 200),
        last_error_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  @doc """
  Records that a delivery to a relay went through, and clears the last error.
  """
  @spec record_success(String.t()) :: :ok
  def record_success(inbox_url) do
    now = DateTime.utc_now()

    Relay
    |> where([r], r.inbox_url == ^inbox_url)
    |> Repo.update_all(
      set: [last_error: nil, last_error_at: nil, last_delivery_at: now, updated_at: now]
    )

    :ok
  end

  @doc """
  One relay by id, or `nil`.
  """
  @spec get(term()) :: Relay.t() | nil
  def get(id) do
    case Integer.parse(to_string(id)) do
      {parsed, ""} -> Repo.get(Relay, parsed)
      _ -> nil
    end
  end
end

defmodule Abuuba.Federation.InstanceActor do
  @moduledoc """
  The server's own actor.

  Some servers run in authorized-fetch mode, where even reading a public post
  requires a signed request. Signing those with a person's key would attribute
  every fetch this server makes to whichever user happened to trigger it, which
  leaks their reading habits to every server they ever look at. So the server
  signs as itself.

  It sits at the reserved id from `Abuuba.Accounts.instance_actor_id/0` rather
  than taking one from the sequence, because other servers cache it by URL and
  that URL has to survive the database being rebuilt.
  """

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs
  alias Abuuba.Repo

  @doc """
  The instance actor, creating it and its signing key if this is the first ask.

  Still lazy, so that a fresh database is a working server and nobody has to
  remember a setup step. `ensure!/0` runs at startup so that in practice the
  first ask is ours rather than a stranger's, and this stays as the answer for
  a database that appeared afterwards.
  """
  @spec fetch!() :: Account.t()
  def fetch! do
    case Accounts.get_account(Accounts.instance_actor_id()) do
      %Account{} = actor -> actor
      nil -> create!()
    end
  end

  @doc """
  Makes the actor now, if it does not exist yet.

  Called when the application starts, so that no peer's request is the one that
  builds it. Two reasons, and the second is the one that matters.

  It costs about a quarter of a second against ten milliseconds warm, which is
  a latency spike on exactly one request and would be tolerable on its own.

  And two peers asking at the same moment on a fresh server both find nothing
  and both try to create it. The id is fixed -- it has to be, because other
  servers cache this actor by URL and it must survive the database being
  rebuilt -- so the second insert loses on the primary key. What that costs is
  out of all proportion to how narrow it is: a server in authorized-fetch mode
  fetches this actor to check a signature, and Mastodon opens its breaker after
  a single failure and holds it open for five minutes. One 500 here is every
  signed request abuuba makes to that server refused for the next five minutes.
  """
  @spec ensure!() :: :ok
  def ensure! do
    _actor = fetch!()

    :ok
  end

  @doc """
  The `{key id, private key}` pair outbound requests sign with, cached.

  This runs on every outbound signed request — delivery is the heaviest
  outbound user by far — and without the cache each request re-read the actor
  and its keypair and re-decrypted the private key. The actor is created once
  and the key rotates roughly never; `Abuuba.Accounts.create_keypair/1` calls
  `invalidate_signing_key/0`, and the TTL catches a rotation this node never
  heard about.

  The decrypted private half sits in the cache's ETS table between uses.
  That trades a little exposure — any process in this VM could read it, and
  it appears in a crash dump — for not re-decrypting on every delivery; the
  key is already in some process heap whenever a request signs, so in-VM
  secrecy was never on offer.
  """
  @spec signing_key() :: {String.t(), String.t()} | nil
  def signing_key do
    Abuuba.Cache.fetch(:instance_signing_key, :timer.minutes(5), fn ->
      actor = fetch!()

      case Accounts.active_keypair(actor) do
        nil -> nil
        keypair -> {Signature.key_id(actor.uri), keypair.private_key}
      end
    end)
  end

  @doc """
  Drops the cached signing key. The key's cache entry lives here so that the
  name cannot drift apart between the writer and the reader.
  """
  @spec invalidate_signing_key() :: :ok
  def invalidate_signing_key, do: Abuuba.Cache.invalidate(:instance_signing_key)

  # Losing the race is not a failure: somebody else made the actor between the
  # read above and this insert, and the answer they made is the answer.
  defp create! do
    create()
  rescue
    Ecto.ConstraintError -> Repo.reload!(%Account{id: Accounts.instance_actor_id()})
  end

  defp create do
    {:ok, actor} =
      Accounts.create_internal_actor(%{
        id: Accounts.instance_actor_id(),
        # Named after the host, which is what the rest of the fediverse expects
        # to see for a server's own actor. Without the port: a development
        # server calls itself `localhost:4000`, and a colon is not a username.
        username: URIs.local_host(),
        actor_type: :application,
        uri: URIs.base_url() <> "/actor",
        url: URIs.base_url() <> "/actor",
        inbox_url: URIs.base_url() <> "/actor/inbox",
        shared_inbox_url: URIs.shared_inbox_url(),
        # Nothing about this actor should turn up in a directory or a search:
        # it is not a person and following it means nothing.
        discoverable: false,
        indexable: false,
        locked: true
      })

    {:ok, _keypair} = Accounts.create_keypair(actor)

    Repo.reload!(actor)
  end
end

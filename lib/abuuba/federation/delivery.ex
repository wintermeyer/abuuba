defmodule Abuuba.Federation.Delivery do
  @moduledoc """
  Working out who an activity has to reach, and getting it there.

  ## One delivery per server, not per follower

  An account with two thousand followers on one large instance does not need
  two thousand deliveries to that instance. Every actor whose server publishes
  a shared inbox is collapsed onto it, so the work is proportional to the
  number of servers involved rather than to the number of people. On a popular
  post that is the difference between a few hundred requests and a few hundred
  thousand.

  Actors whose servers publish no shared inbox still get their own delivery.
  There is nowhere else to put it.

  ## Who is in reach

  Followers, plus anybody mentioned, plus the author of anything being replied
  to or boosted. The last two matter because they are how a conversation stays
  joined up: a reply that never reaches the person replied to is a reply they
  never see, however many of their followers get it.

  Subscribed relays are in reach too, but only for public statuses. See
  `Abuuba.Federation.Relays` for why anything less than public stops there.

  ## Servers that have stopped answering

  Filtered out once, at the end, by the host of the inbox rather than by where
  the inbox came from: we do not deliver to a domain we have given up on,
  whether it turned up as somebody's follower, as a mention or as a relay. See
  `Abuuba.Federation.Availability` for why that is counted in days.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.DeliveryWorker
  alias Abuuba.Federation.FollowerSync
  alias Abuuba.Federation.Relays
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs
  alias Abuuba.Moderation.Domains
  alias Abuuba.Relationships.Follow
  alias Abuuba.Repo
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Status

  @doc """
  Sends an activity to everybody it has to reach.

  One job per inbox, so that one unreachable server does not hold up delivery
  to every other server on the same post.
  """
  @spec distribute(Account.t(), map(), keyword()) :: :ok
  def distribute(%Account{} = account, activity, opts \\ []) do
    status = Keyword.get(opts, :status)
    # Loaded once and passed on: the audience needs it and so does the
    # synchronisation header, and it is one query per popular account.
    followers = remote_followers(account)

    inboxes = inboxes_for_accounts(audience(status, followers)) ++ relay_inboxes(status)

    deliver_to(inboxes, activity, account, headers: synchronisation(account, followers, status))
  end

  @doc """
  Queues an activity for a list of inboxes, signed as `signer`.

  The one way anything reaches the push queue, and therefore where a server we
  will not talk to is dropped: a domain a moderator suspended, and one that
  stopped answering a week ago. That decision used to be made by the callers
  that happened to think of it, so anything assembling its own inbox list went
  straight past -- a forwarded report was signed by the instance actor and
  posted to a domain that had just been cut off. Deciding it here costs the
  same two queries it always did and cannot be forgotten by the next caller.

  Relay subscriptions come through here as well as status distribution, so
  which key signs and how a job is built stay in one place.

  `:headers` maps a destination domain to the extra headers its delivery
  carries, because the only such header so far describes that one server's
  followers and so differs for every inbox in the same distribution.
  """
  @spec deliver_to([String.t()], map(), Account.t(), keyword()) :: :ok
  def deliver_to(inboxes, activity, %Account{} = signer, opts \\ []) do
    inboxes
    |> reachable()
    |> DeliveryWorker.enqueue(activity,
      account_id: signer.id,
      key_id: Signature.key_id(Actor.id(signer)),
      headers: Keyword.get(opts, :headers, %{})
    )
  end

  @doc """
  Queues an activity for one account, where that account is somewhere else.

  A follow, its acceptance, a favourite, a block: things addressed to one actor
  rather than published. Their personal inbox rather than their server's shared
  one, because a shared inbox is a batching optimisation for something being
  sent to many people on that server and this is being sent to one.

  Nothing is queued for an account that lives here, which has no inbox to
  deliver to and needs no server in between.
  """
  @spec deliver_to_account(Account.t(), map(), Account.t()) :: :ok
  def deliver_to_account(%Account{domain: nil}, _activity, _signer), do: :ok

  def deliver_to_account(%Account{inbox_url: inbox}, activity, %Account{} = signer)
      when is_binary(inbox) and inbox != "" do
    deliver_to([inbox], activity, signer)
  end

  def deliver_to_account(%Account{}, _activity, _signer), do: :ok

  @doc """
  The inboxes an activity from `account` about `status` has to reach.

  Returns one entry per inbox, already deduplicated onto shared inboxes and
  with servers we have given up on removed.
  """
  @spec inboxes_for(Account.t(), Status.t() | nil) :: [String.t()]
  def inboxes_for(%Account{} = account, status \\ nil) do
    status
    |> audience(remote_followers(account))
    |> inboxes_for_accounts()
    |> Kernel.++(relay_inboxes(status))
    |> reachable()
  end

  # The accounts an activity has to reach. One definition, used by both the
  # distribution and the answer to "who would this reach": they were two copies
  # of the same expression, and only one of them learned about direct messages.
  #
  # A direct message reaches the people it names and nobody else. The author's
  # followers are deliberately absent: they are the audience for everything
  # else this account writes, and delivering a direct message to them is the
  # one thing that visibility exists to prevent. The people already in the
  # thread stay, because a reply the person replied to never sees is a reply
  # they never see.
  defp audience(%Status{visibility: visibility} = status, _followers)
       when visibility in [:direct, :limited] do
    Enum.uniq_by(mentioned(status) ++ conversation_partners(status), & &1.id)
  end

  defp audience(status, followers) do
    Enum.uniq_by(followers ++ mentioned(status) ++ conversation_partners(status), & &1.id)
  end

  defp inboxes_for_accounts(accounts) do
    accounts
    |> Enum.map(&inbox_for/1)
    |> Enum.reject(&is_nil/1)
  end

  # One availability query for the whole distribution rather than one per
  # follower: a popular post reaches thousands of people across a few hundred
  # servers, and there are only ever as many answers as there are servers.
  defp reachable(inboxes) do
    inboxes = Enum.uniq(inboxes)
    hosts = Enum.map(inboxes, &URIs.host_of/1)
    # Two questions with the same answer for delivery, asked separately because
    # they mean different things: one server has stopped answering, the other
    # is one this server has decided not to talk to.
    skip =
      hosts
      |> Availability.unavailable_among()
      |> MapSet.union(Domains.refused_among(hosts))

    inboxes
    |> Enum.zip(hosts)
    |> Enum.reject(fn {_inbox, host} -> is_nil(host) or MapSet.member?(skip, host) end)
    |> Enum.map(fn {inbox, _host} -> inbox end)
  end

  # FEP-8fcf, and only where it says something. A followers-only status is
  # distributed by follower list, so a peer's list being wrong is exactly the
  # failure the digest catches. A public status reaches people who follow
  # nobody, and a direct one goes to named accounts rather than to the
  # collection, so in both cases the digest would describe something other than
  # what was delivered.
  #
  # Every domain's digest comes out of one pass over the follower list. Asking
  # per destination would walk the whole list once per server on the receiving
  # end of a popular account. It covers followers only, because that is what
  # the collection a peer then fetches contains: counting a mentioned stranger
  # would make the two disagree by construction.
  defp synchronisation(account, followers, %Status{visibility: :private}) do
    followers
    |> FollowerSync.digests_by_domain()
    |> Map.new(fn {domain, digest} ->
      {domain, %{"collection-synchronization" => FollowerSync.header(account, domain, digest)}}
    end)
  end

  defp synchronisation(_account, _followers, _status), do: %{}

  # A shared inbox where the server offers one. This is the whole reason a
  # popular post costs a few hundred requests rather than a few hundred
  # thousand.
  defp inbox_for(%{shared_inbox_url: shared}) when is_binary(shared) and shared != "", do: shared
  defp inbox_for(%{inbox_url: inbox}) when is_binary(inbox) and inbox != "", do: inbox
  defp inbox_for(_account), do: nil

  # Public only. A relay redistributes to strangers, which is the one thing a
  # status that is not public has asked us not to do.
  defp relay_inboxes(%Status{visibility: :public}), do: Relays.inboxes()
  defp relay_inboxes(_status), do: []

  # Only the columns delivery needs. The wide account row carries a note, a
  # display name and a pile of profile fields that nothing here reads, and this
  # query loads one row per follower.
  @audience_fields [:id, :domain, :uri, :inbox_url, :shared_inbox_url]

  defp remote_followers(account) do
    Follow
    |> join(:inner, [f], a in Account, on: a.id == f.account_id)
    |> where([f, a], f.target_account_id == ^account.id and not is_nil(a.domain))
    |> select([_f, a], map(a, ^@audience_fields))
    |> Repo.all()
  end

  defp mentioned(nil), do: []

  defp mentioned(%Status{id: status_id}) do
    Mention
    |> join(:inner, [m], a in Account, on: a.id == m.account_id)
    |> where([m, a], m.status_id == ^status_id and not is_nil(a.domain))
    |> select([_m, a], map(a, ^@audience_fields))
    |> Repo.all()
  end

  # The author of what is being replied to or boosted. A reply that never
  # reaches the person replied to is a reply they never see, however many of
  # their followers get it.
  defp conversation_partners(nil), do: []

  defp conversation_partners(%Status{} = status) do
    ids =
      [status.in_reply_to_account_id, boosted_author_id(status)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Account
    |> where([a], a.id in ^ids and not is_nil(a.domain))
    |> select([a], map(a, ^@audience_fields))
    |> Repo.all()
  end

  defp boosted_author_id(%Status{reblog_of_id: nil}), do: nil

  defp boosted_author_id(%Status{reblog_of_id: id}) do
    Status |> where([s], s.id == ^id) |> select([s], s.account_id) |> Repo.one()
  end
end

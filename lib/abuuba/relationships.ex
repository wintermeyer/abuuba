defmodule Abuuba.Relationships do
  @moduledoc """
  Who follows, blocks, mutes and annotates whom.

  Two things here are more than bookkeeping.

  A block is not just an edge. Creating one tears down everything that connects
  the two accounts: follows in both directions, and any pending request either
  way. Leaving those in place is how somebody stays subscribed to an account
  that has refused them, and the API's relationship object would then report
  both "blocking" and "followed_by" at once.

  Accepting a follow request moves a row from `follow_requests` to `follows` in
  one transaction. The two tables share a shape so that nothing chosen at
  request time is lost at the moment of acceptance.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.ActionLimits
  alias Abuuba.Federation.Outbox
  alias Abuuba.Notifications
  alias Abuuba.Pagination
  alias Abuuba.Relationships.Block
  alias Abuuba.Relationships.DomainBlock
  alias Abuuba.Relationships.Endorsement
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.FollowRequest
  alias Abuuba.Relationships.Mute
  alias Abuuba.Relationships.Note
  alias Abuuba.Repo
  alias Abuuba.Stats
  alias Abuuba.Timelines
  alias Ecto.Multi

  ## Following

  @doc """
  Follows an account outright, whatever that account asked for. Anything a
  person presses goes through `follow_or_request/3` instead, which asks an
  account that approves its followers rather than following it.

  Refused if either account has blocked the other: a follow that a block would
  immediately have to undo should never come into being.
  """
  @spec follow(Account.t() | integer(), Account.t() | integer(), map()) ::
          {:ok, Follow.t()} | {:error, :blocked | Ecto.Changeset.t()}
  def follow(follower, target, attrs \\ %{})

  def follow(%Account{id: follower_id}, target, attrs), do: follow(follower_id, target, attrs)

  def follow(follower_id, %Account{id: target_id}, attrs),
    do: follow(follower_id, target_id, attrs)

  def follow(follower_id, target_id, attrs) do
    cond do
      blocked_either_way?(follower_id, target_id) ->
        {:error, :blocked}

      # Following somebody already followed is how the options are changed:
      # "follow, but not the boosts" arrives as the same request whether or not
      # the follow already exists, and a unique-constraint error would be a
      # confusing answer to it.
      existing = get_edge(Follow, follower_id, target_id) ->
        existing |> Follow.changeset(edge_attrs(attrs, follower_id, target_id)) |> Repo.update()

      true ->
        with {:ok, follow} <- insert_follow(follower_id, target_id, attrs) do
          # What the follower can already read, brought in now. A follow that
          # shows nothing until the next post looks broken.
          Timelines.merge_account(follower_id, target_id)
          # Only here, in the clause that creates one. `follow/3` is also how
          # the settings on an existing follow are changed, and turning boosts
          # off must not read as somebody following all over again.
          Notifications.notify(target_id, follower_id, "follow")
          Outbox.followed(follow)

          {:ok, follow}
        end
    end
  end

  defp insert_follow(follower_id, target_id, attrs) do
    Multi.new()
    |> Multi.insert(
      :follow,
      Follow.changeset(%Follow{}, edge_attrs(attrs, follower_id, target_id))
    )
    |> Multi.run(:counters, fn _repo, _changes ->
      Stats.bump_account(follower_id, following_count: 1)
      Stats.bump_account(target_id, followers_count: 1)
      {:ok, :counted}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{follow: follow}} -> {:ok, follow}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Stops following. Returns `:ok` whether or not there was a follow to remove,
  so that a client retrying an unfollow does not get an error for succeeding.
  """
  @spec unfollow(Account.t() | integer(), Account.t() | integer()) :: :ok
  def unfollow(%Account{id: follower_id}, target), do: unfollow(follower_id, target)
  def unfollow(follower_id, %Account{id: target_id}), do: unfollow(follower_id, target_id)

  def unfollow(follower_id, target_id) do
    # Read before the delete: the `Undo` has to name the id of the `Follow` the
    # other server stored, which is derived from this row.
    going = get_edge(Follow, follower_id, target_id)

    {deleted, _} =
      Follow
      |> where([f], f.account_id == ^follower_id and f.target_account_id == ^target_id)
      |> Repo.delete_all()

    if deleted > 0 do
      # "X followed you" from somebody who is not following, with a card
      # offering to follow them back, is the interface arguing with itself.
      Notifications.forget(target_id, follower_id, "follow")
      Outbox.unfollowed(going)
      Stats.bump_account(follower_id, following_count: -1)
      Stats.bump_account(target_id, followers_count: -1)

      # Their posts stop arriving from now on either way. This is what clears
      # the ones already in the feed, and without it somebody who just
      # unfollowed keeps reading them until the cap pushes them out. Boosts of
      # them go too, and anything still reachable another way stays.
      Timelines.unmerge_account(follower_id, target_id)

      # An endorsement is "follow this person too". Somebody who has stopped
      # following them is no longer saying that, and leaving it on the profile
      # would leave a recommendation nobody meant to keep making. Blocking
      # unfollows first, so this covers that too.
      delete_edge(Endorsement, follower_id, target_id)
    end

    # A request nobody has answered yet is the follow until they answer it, so
    # whatever stops a follow stops this too. Without it, somebody who asked an
    # account that never answers has no way out of waiting.
    withdraw_request(follower_id, target_id)

    :ok
  end

  @doc """
  Asks to follow an account that approves its followers.
  """
  @spec request_follow(Account.t() | integer(), Account.t() | integer(), map()) ::
          {:ok, FollowRequest.t()} | {:error, :blocked | Ecto.Changeset.t()}
  def request_follow(follower, target, attrs \\ %{})

  def request_follow(%Account{id: follower_id}, target, attrs),
    do: request_follow(follower_id, target, attrs)

  def request_follow(follower_id, %Account{id: target_id}, attrs),
    do: request_follow(follower_id, target_id, attrs)

  def request_follow(follower_id, target_id, attrs) do
    if blocked_either_way?(follower_id, target_id) do
      {:error, :blocked}
    else
      %FollowRequest{}
      |> FollowRequest.changeset(edge_attrs(attrs, follower_id, target_id))
      |> Repo.insert()
      |> tap(fn
        # The same `Follow` activity a plain follow sends. Whether it is
        # granted is the other server's decision, not ours to anticipate.
        {:ok, request} ->
          Notifications.notify(target_id, follower_id, "follow_request")
          Outbox.followed(request)

        _ ->
          :ok
      end)
    end
  end

  @doc """
  Follows an account, or asks it, whichever that account has said it wants.

  The one door behind every "Follow" a person presses -- the profile, the
  explore list, the API, a follow list being imported -- so that an account
  which approves its followers is asked wherever the button is drawn, and not
  only where somebody remembered to check. `follow/3` stays the way in for the
  paths that mean an outright follow: a move carrying followers to a new
  account, an invite whose owner asked for them.
  """
  @spec follow_or_request(Account.t(), Account.t(), map()) ::
          {:ok, Follow.t() | FollowRequest.t()} | {:error, :blocked | Ecto.Changeset.t()}
  def follow_or_request(follower, target, attrs \\ %{})

  def follow_or_request(%Account{} = follower, %Account{} = target, attrs) do
    # A follow already granted is changed by a repeat follow, on an account
    # that approves its followers like on any other: somebody who locked their
    # account afterwards has answered for the people already following them,
    # and a fresh request would sit beside a follow that is already in place.
    if approves_followers?(target) and not following?(follower, target) do
      ask_to_follow(follower, target, attrs)
    else
      follow(follower, target, attrs)
    end
  end

  # Asking twice is one request rather than an error: the second press carries
  # whatever changed, the same way a repeat follow does.
  defp ask_to_follow(follower, target, attrs) do
    case get_follow_request(follower, target) do
      nil ->
        request_follow(follower, target, attrs)

      pending ->
        pending
        |> FollowRequest.changeset(edge_attrs(attrs, follower.id, target.id))
        |> Repo.update()
    end
  end

  # Read from the row, not from the copy the caller is holding: a profile open
  # in a browser was built when the page loaded, and what decides this is
  # whether the account approves its followers at the moment of the press.
  defp approves_followers?(%Account{id: id}) do
    Account
    |> where([a], a.id == ^id)
    |> select([a], a.locked)
    |> Repo.one()
  end

  @doc """
  Accepts a pending request, turning it into a follow.

  One transaction, carrying every setting across. Done as two steps, a failure
  in between either drops the request without granting the follow or leaves
  both in place, and the second is worse: the requester appears in the pending
  list forever while already following.
  """
  @spec accept_follow_request(FollowRequest.t()) ::
          {:ok, Follow.t()} | {:error, Ecto.Changeset.t()}
  def accept_follow_request(%FollowRequest{} = request) do
    Multi.new()
    |> Multi.delete(:request, request)
    |> Multi.insert(
      :follow,
      Follow.changeset(%Follow{}, %{
        account_id: request.account_id,
        target_account_id: request.target_account_id,
        show_reblogs: request.show_reblogs,
        notify: request.notify,
        languages: request.languages,
        uri: request.uri
      })
    )
    |> Multi.run(:counters, fn _repo, _changes ->
      Stats.bump_account(request.account_id, following_count: 1)
      Stats.bump_account(request.target_account_id, followers_count: 1)
      {:ok, :counted}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{follow: follow}} ->
        forget_request(request)
        Notifications.notify(request.target_account_id, request.account_id, "follow")
        Outbox.follow_accepted(request)
        {:ok, follow}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Turns down a pending request.
  """
  @spec reject_follow_request(FollowRequest.t()) :: :ok
  def reject_follow_request(%FollowRequest{} = request) do
    Repo.delete(request)
    forget_request(request)
    # Told rather than left waiting. A request that simply vanishes leaves the
    # asker's client showing "pending" forever.
    Outbox.follow_rejected(request)
    :ok
  end

  # The request is gone either way, whether it was refused or granted, so the
  # notification asking about it has nothing left to point at. Granting one
  # replaces it with a follow, which announces itself.
  defp forget_request(%FollowRequest{} = request) do
    Notifications.forget(request.target_account_id, request.account_id, "follow_request")
  end

  @doc """
  The pending request between two accounts, or `nil`.
  """
  @spec get_follow_request(Account.t() | integer(), Account.t() | integer()) ::
          FollowRequest.t() | nil
  def get_follow_request(follower, target),
    do: get_edge(FollowRequest, follower, target)

  @doc """
  Whether one account follows another.
  """
  @spec following?(Account.t() | integer(), Account.t() | integer()) :: boolean()
  def following?(follower, target), do: get_edge(Follow, follower, target) != nil

  @doc """
  The follow between two accounts, or `nil`.

  Distinct from `following?/2` because the row carries the settings that ride
  on a follow — the boosts, the notifications, the languages — and a screen
  offering those has to render what they currently are.
  """
  @spec get_follow(Account.t() | integer(), Account.t() | integer()) :: Follow.t() | nil
  def get_follow(follower, target), do: get_edge(Follow, follower, target)

  @doc """
  Puts somebody on your profile as worth following.

  Only somebody you follow. An endorsement is a public recommendation and it
  survives on the profile until it is taken down, so allowing one for somebody
  who has blocked you would hand every blocked account a way to keep naming the
  person who blocked them. The follow requirement is the reference
  implementation's rule and it is what makes the endorsement fall away on its
  own: unfollowing or blocking removes it.

  Says nothing about what either account may read or receive, and the person
  endorsed is neither asked nor told. Endorsing twice is endorsing once.
  """
  @spec endorse(Account.t() | integer(), Account.t() | integer()) ::
          :ok | {:error, :not_following}
  def endorse(%Account{id: id}, target), do: endorse(id, target)
  def endorse(account_id, %Account{id: target_id}), do: endorse(account_id, target_id)

  def endorse(account_id, target_account_id) do
    if following?(account_id, target_account_id) do
      now = DateTime.utc_now()

      Repo.insert_all(
        Endorsement,
        [
          %{
            account_id: account_id,
            target_account_id: target_account_id,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:account_id, :target_account_id]
      )

      :ok
    else
      {:error, :not_following}
    end
  end

  @doc """
  Takes them back off it.
  """
  @spec unendorse(Account.t() | integer(), Account.t() | integer()) :: :ok
  def unendorse(account, target), do: delete_edge(Endorsement, account, target)

  @doc """
  Whether one account endorses another.
  """
  @spec endorsed?(Account.t() | integer(), Account.t() | integer()) :: boolean()
  def endorsed?(account, target), do: get_edge(Endorsement, account, target) != nil

  @doc """
  Who an account has endorsed, newest first.

  Suspended accounts are left out. An endorsement is a recommendation, and
  recommending somebody this server has taken down is the one thing it must
  not keep doing on their behalf.
  """
  @spec endorsements(Account.t() | integer(), map()) :: [Account.t()]
  def endorsements(%Account{id: id}, page), do: endorsements(id, page)

  def endorsements(account_id, page) do
    Endorsement
    |> join(:inner, [e], a in Account, on: a.id == e.target_account_id)
    |> where([e], e.account_id == ^account_id)
    |> where([_e, a], is_nil(a.suspended_at))
    |> paginate_by_account(nil, page, :target_account_id)
  end

  @doc """
  How many accounts on one domain the reader follows.
  """
  @spec following_on_domain(Account.t() | integer(), String.t()) :: non_neg_integer()
  def following_on_domain(%Account{id: id}, domain), do: following_on_domain(id, domain)

  def following_on_domain(account_id, domain) do
    count_on_domain(account_id, domain, :target_account_id, :account_id)
  end

  @doc """
  How many of the reader's followers are on it.
  """
  @spec followers_on_domain(Account.t() | integer(), String.t()) :: non_neg_integer()
  def followers_on_domain(%Account{id: id}, domain), do: followers_on_domain(id, domain)

  def followers_on_domain(account_id, domain) do
    count_on_domain(account_id, domain, :account_id, :target_account_id)
  end

  defp count_on_domain(_account_id, domain, _other, _mine) when domain in [nil, ""], do: 0

  defp count_on_domain(account_id, domain, other, mine) do
    Follow
    |> join(:inner, [f], a in Account, on: a.id == field(f, ^other))
    |> where([f], field(f, ^mine) == ^account_id)
    |> where([_f, a], a.domain == ^domain)
    |> Repo.aggregate(:count)
  end

  @doc """
  Both directions of the follow edge between two accounts, in one query.

  For callers that need "do I follow them" and "do they follow me" together —
  the notification policy asks exactly this for every notification it files.
  """
  @spec between(integer(), integer()) :: %{following: boolean(), followed_by: boolean()}
  def between(account_id, other_id) do
    edges =
      Follow
      |> where(
        [f],
        (f.account_id == ^account_id and f.target_account_id == ^other_id) or
          (f.account_id == ^other_id and f.target_account_id == ^account_id)
      )
      |> select([f], {f.account_id, f.target_account_id})
      |> Repo.all()

    %{
      following: {account_id, other_id} in edges,
      followed_by: {other_id, account_id} in edges
    }
  end

  @doc """
  The ids of the accounts an account follows.
  """
  @spec following_ids(Account.t() | integer()) :: [integer()]
  def following_ids(%Account{id: id}), do: following_ids(id)

  def following_ids(account_id) do
    Follow
    |> where([f], f.account_id == ^account_id)
    |> select([f], f.target_account_id)
    |> Repo.all()
  end

  @doc """
  The ids of the accounts an account has asked to follow and is waiting on.
  """
  @spec requested_ids(Account.t() | integer()) :: [integer()]
  def requested_ids(%Account{id: id}), do: requested_ids(id)

  def requested_ids(account_id) do
    FollowRequest
    |> where([r], r.account_id == ^account_id)
    |> select([r], r.target_account_id)
    |> Repo.all()
  end

  @doc """
  The ids of an account's followers.
  """
  @spec follower_ids(Account.t() | integer()) :: [integer()]
  def follower_ids(%Account{id: id}), do: follower_ids(id)

  def follower_ids(account_id) do
    Follow
    |> where([f], f.target_account_id == ^account_id)
    |> select([f], f.account_id)
    |> Repo.all()
  end

  @doc """
  The ids of the accounts on this server that follow an account.
  """
  @spec local_follower_ids(Account.t() | integer()) :: [integer()]
  def local_follower_ids(%Account{id: id}), do: local_follower_ids(id)

  def local_follower_ids(account_id) do
    Follow
    |> join(:inner, [f], a in Account, on: a.id == f.account_id)
    |> where([f, _a], f.target_account_id == ^account_id)
    |> where([_f, a], is_nil(a.domain))
    |> select([f, _a], f.account_id)
    |> Repo.all()
  end

  @doc """
  Tells another server to stop delivering to somebody who does not follow.

  For the one case where they believe in a follow we have no row for, found by
  reconciling follower lists. There is nothing to delete here, so this only
  sends: an `Undo` of a `Follow` built from the two accounts, carrying an id we
  made up because the original was never ours. A peer that matches undos by
  activity id alone will ignore it, which is the compromise the reference
  implementation makes too, and the alternative is leaving them delivering
  forever.
  """
  @spec withdraw_unknown_follow(Account.t(), Account.t()) :: :ok
  def withdraw_unknown_follow(%Account{} = follower, %Account{} = target) do
    Outbox.unfollowed(%Follow{account_id: follower.id, target_account_id: target.id})
  end

  ## Blocking

  @doc """
  Blocks an account, and severs everything between the two.
  """
  @spec block(Account.t() | integer(), Account.t() | integer()) ::
          {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def block(%Account{id: blocker_id}, target), do: block(blocker_id, target)
  def block(blocker_id, %Account{id: target_id}), do: block(blocker_id, target_id)

  def block(blocker_id, target_id) do
    result =
      %Block{}
      |> Block.changeset(%{account_id: blocker_id, target_account_id: target_id})
      |> Repo.insert()

    with {:ok, block} <- result do
      # Both directions, and `unfollow/2` takes the unanswered requests with
      # it. A block that left the blocked account still following would have
      # the API report "blocking" and "followed_by" at once.
      unfollow(blocker_id, target_id)
      unfollow(target_id, blocker_id)

      # Both feeds, not only the blocker's: a block means neither of them is
      # reading the other, and `unfollow/2` above only clears one side when
      # only one side was following. Posts that merely mention the other person
      # go too, since a post naming somebody carries their handle in with it.
      Timelines.purge_account(blocker_id, target_id)
      Timelines.purge_account(target_id, blocker_id)

      Outbox.blocked(block)

      {:ok, block}
    end
  end

  @doc """
  Unblocks. Does not restore the follows the block tore down; those have to be
  made again, which is the behaviour people expect.
  """
  @spec unblock(Account.t() | integer(), Account.t() | integer()) :: :ok
  def unblock(blocker, target) do
    # Read before the delete, for the id the `Undo` has to name.
    going = get_edge(Block, blocker, target)

    :ok = delete_edge(Block, blocker, target)

    if going, do: Outbox.unblocked(going)

    :ok
  end

  @doc """
  Whether one account blocks another.
  """
  @spec blocking?(Account.t() | integer(), Account.t() | integer()) :: boolean()
  def blocking?(blocker, target), do: get_edge(Block, blocker, target) != nil

  @doc """
  Whether `viewer` may see who `subject` follows and who follows them.

  Three questions in one order. Your own lists are always yours to see, and
  the setting outranks everything after it -- `hide_collections` is somebody
  saying "do not show who I know", and a reader they have not blocked is no
  more entitled than one they have. Then a block: a profile that shows the
  person it blocked who its followers are has not blocked them, and the list
  is the part they came for.

  Here rather than at each surface because it was written four times in four
  shapes: a function head in the REST controller, a `cond` with two private
  helpers in the profile page, a single pattern match in the ActivityPub
  controller, and a fourth spelling guarding the featured strip. The tell that
  nobody could reuse it is that two of the comments each said the *other*
  surfaces already honoured the setting.

  `nil` for a reader with no account, and for the federation side, whose
  documented answer to a hidden collection is an empty one rather than a
  refusal.
  """
  @spec collections_visible?(Account.t(), Account.t() | nil) :: boolean()
  def collections_visible?(%Account{id: id}, %Account{id: id}), do: true
  def collections_visible?(%Account{hide_collections: true}, _viewer), do: false
  def collections_visible?(_subject, nil), do: true
  def collections_visible?(subject, viewer), do: not blocking?(subject, viewer)

  ## Muting

  @doc """
  Mutes an account. Pass `hide_notifications: false` to keep being notified,
  and `expires_at` for a mute that lifts itself.
  """
  @spec mute(Account.t() | integer(), Account.t() | integer(), map()) ::
          {:ok, Mute.t()} | {:error, Ecto.Changeset.t()}
  def mute(muter, target, attrs \\ %{})
  def mute(%Account{id: muter_id}, target, attrs), do: mute(muter_id, target, attrs)
  def mute(muter_id, %Account{id: target_id}, attrs), do: mute(muter_id, target_id, attrs)

  def mute(muter_id, target_id, attrs) do
    with {:ok, mute} <-
           %Mute{} |> Mute.changeset(edge_attrs(attrs, muter_id, target_id)) |> Repo.insert() do
      # Cleared from the feed as well as filtered on read. The read-time check
      # is what makes a mute reversible; this is what makes it take effect on
      # the page somebody is already looking at.
      Timelines.purge_account(muter_id, target_id)

      {:ok, mute}
    end
  end

  @doc """
  Unmutes.
  """
  @spec unmute(Account.t() | integer(), Account.t() | integer()) :: :ok
  def unmute(muter, target) do
    :ok = delete_edge(Mute, muter, target)

    # Their posts come back. A mute is a temporary thing somebody sets for an
    # afternoon, and finding that everything said during it is gone for good
    # would make muting a decision people are afraid to make. Unblocking is not
    # the same: a block tears down the follow, so there is nothing to bring
    # back until somebody follows again.
    Timelines.merge_account(muter, target)
  end

  @doc """
  Whether a mute is in force right now. An expired mute is not.
  """
  @spec muting?(Account.t() | integer(), Account.t() | integer()) :: boolean()
  def muting?(muter, target) do
    case get_edge(Mute, muter, target) do
      nil -> false
      mute -> Mute.active?(mute)
    end
  end

  @doc """
  Whether a notification from `sender` should reach `reader` at all.

  Three ways it should not, and they are decisions the reader has already
  made: they blocked the sender, they muted them and left "hide notifications"
  on, or they blocked the whole domain the sender is on.

  The mute half is the one that was doing nothing. `hide_notifications`
  defaults to true whenever anybody mutes anybody, and it is written by the
  API, carried in an export and read back by the importer -- so a person who
  muted somebody was told about every favourite that person made afterwards,
  by a flag that said it would not.
  """
  @spec notifications_silenced?(Account.t() | integer(), Account.t() | integer()) :: boolean()
  def notifications_silenced?(reader, sender) do
    blocking?(reader, sender) or notifications_muted?(reader, sender) or
      domain_blocked?(reader, sender)
  end

  defp notifications_muted?(reader, sender) do
    case get_edge(Mute, reader, sender) do
      nil -> false
      mute -> Mute.active?(mute) and mute.hide_notifications
    end
  end

  @doc """
  Whether a reader has shut out the server one account is on.

  Takes the account rather than the domain, because a caller holding a post
  holds its author's id and not their hostname. A local author is on no server
  a reader can block, so they are never hidden by this.
  """
  @spec domain_blocked?(Account.t() | integer(), Account.t() | integer()) :: boolean()
  def domain_blocked?(reader, sender) do
    case account_of(sender) do
      %Account{domain: domain} when is_binary(domain) ->
        DomainBlock
        |> where([d], d.account_id == ^id_of(reader) and d.domain == ^domain)
        |> Repo.exists?()

      _local_or_missing ->
        false
    end
  end

  defp account_of(%Account{} = account), do: account
  defp account_of(id), do: Repo.get(Account, id)

  defp id_of(%Account{id: id}), do: id
  defp id_of(id), do: id

  @doc """
  Deletes mutes whose time has run out. For a periodic sweep; `muting?/2`
  already ignores them, so nothing depends on this having run.
  """
  @spec expire_mutes() :: non_neg_integer()
  def expire_mutes do
    now = DateTime.utc_now()

    {deleted, _} =
      Mute
      |> where([m], not is_nil(m.expires_at) and m.expires_at <= ^now)
      |> Repo.delete_all()

    deleted
  end

  ## Domain blocks

  @doc """
  Blocks a whole server, for this account only.
  """
  @spec block_domain(Account.t() | integer(), String.t()) ::
          {:ok, DomainBlock.t()} | {:error, Ecto.Changeset.t()}
  def block_domain(%Account{id: id}, domain), do: block_domain(id, domain)

  def block_domain(account_id, domain) do
    %DomainBlock{}
    |> DomainBlock.changeset(%{account_id: account_id, domain: domain})
    |> Repo.insert()
  end

  @doc """
  Lifts a personal domain block.
  """
  @spec unblock_domain(Account.t() | integer(), String.t()) :: :ok
  def unblock_domain(%Account{id: id}, domain), do: unblock_domain(id, domain)

  def unblock_domain(account_id, domain) do
    DomainBlock
    |> where([d], d.account_id == ^account_id)
    |> where([d], d.domain == ^String.downcase(String.trim(domain)))
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Spends one follow from an account's own daily allowance.

  Taken by the places a person presses a button rather than inside `follow/3`,
  because that is also how an inbound Follow, a Move, an invite's autofollow
  and the CSV importer write the row. None of those is somebody spending their
  own budget, and counting the importer would refuse a person bringing their
  own follow list across -- the one moment they legitimately follow hundreds
  of accounts at once.
  """
  @spec take_follow_budget(Account.t() | integer()) :: :ok | {:error, :rate_limited}
  def take_follow_budget(account), do: ActionLimits.take(account, :follows)

  @doc """
  Whether an account has blocked a server.
  """
  @spec blocking_domain?(Account.t() | integer(), String.t() | nil) :: boolean()
  def blocking_domain?(_account, nil), do: false
  def blocking_domain?(%Account{id: id}, domain), do: blocking_domain?(id, domain)

  def blocking_domain?(account_id, domain) do
    DomainBlock
    |> where([d], d.account_id == ^account_id)
    |> where([d], d.domain == ^String.downcase(String.trim(domain)))
    |> Repo.exists?()
  end

  ## Notes

  @doc """
  Writes the private note one account keeps about another, replacing any
  previous one.
  """
  @spec put_note(Account.t() | integer(), Account.t() | integer(), String.t()) ::
          {:ok, Note.t()} | {:error, Ecto.Changeset.t()}
  def put_note(%Account{id: author_id}, subject, comment),
    do: put_note(author_id, subject, comment)

  def put_note(author_id, %Account{id: subject_id}, comment),
    do: put_note(author_id, subject_id, comment)

  def put_note(author_id, subject_id, comment) do
    existing =
      Repo.get_by(Note, account_id: author_id, target_account_id: subject_id) || %Note{}

    existing
    |> Note.changeset(%{
      account_id: author_id,
      target_account_id: subject_id,
      comment: comment
    })
    |> Repo.insert_or_update()
  end

  @doc """
  The note one account keeps about another, or `nil`.
  """
  @spec get_note(Account.t() | integer(), Account.t() | integer()) :: Note.t() | nil
  def get_note(author, subject), do: get_edge(Note, author, subject)

  ## The relationship as a whole

  @doc """
  Everything one account's client needs to know about its relationship to
  another, in one call. The shape the API's relationship object is built from.
  """
  @spec relationship(Account.t() | integer(), Account.t() | integer()) :: map()
  def relationship(%Account{id: id}, other), do: relationship(id, other)
  def relationship(account_id, %Account{id: id}), do: relationship(account_id, id)

  def relationship(account_id, other_id) do
    [answer] = relationships(account_id, [other_id])

    answer
  end

  @doc """
  `relationship/2` for a whole page of accounts, in the order asked.

  A fixed eight queries however many ids arrive. Clients ask this after every
  timeline they fetch, forty ids at a time, and the one-by-one version was
  over two hundred round trips per ask.
  """
  @spec relationships(integer(), [integer()]) :: [map()]
  def relationships(_account_id, []), do: []

  def relationships(account_id, other_ids) do
    follows = edges(Follow, account_id, other_ids)
    followed_by = reverse_edges(Follow, account_id, other_ids)
    blocking = edges(Block, account_id, other_ids)
    blocked_by = reverse_edges(Block, account_id, other_ids)
    mutes = edges(Mute, account_id, other_ids)
    requested = edges(FollowRequest, account_id, other_ids)
    requested_by = reverse_edges(FollowRequest, account_id, other_ids)
    notes = edges(Note, account_id, other_ids)
    endorsed = edges(Endorsement, account_id, other_ids)

    Enum.map(other_ids, fn other_id ->
      follow = follows[other_id]
      mute = mutes[other_id]

      %{
        id: other_id,
        following: follow != nil,
        followed_by: Map.has_key?(followed_by, other_id),
        blocking: Map.has_key?(blocking, other_id),
        blocked_by: Map.has_key?(blocked_by, other_id),
        muting: mute != nil and Mute.active?(mute),
        muting_notifications: mute != nil and Mute.active?(mute) and mute.hide_notifications,
        muting_expires_at: mute_expiry(mute),
        requested: Map.has_key?(requested, other_id),
        requested_by: Map.has_key?(requested_by, other_id),
        showing_reblogs: follow != nil and follow.show_reblogs,
        notifying: follow != nil and follow.notify,
        languages: follow && follow.languages,
        note: (notes[other_id] || %Note{}).comment,
        endorsed: Map.has_key?(endorsed, other_id)
      }
    end)
  end

  defp edges(schema, account_id, other_ids) do
    schema
    |> where([e], e.account_id == ^account_id and e.target_account_id in ^other_ids)
    |> Repo.all()
    |> Map.new(&{&1.target_account_id, &1})
  end

  defp reverse_edges(schema, account_id, other_ids) do
    schema
    |> where([e], e.target_account_id == ^account_id and e.account_id in ^other_ids)
    |> Repo.all()
    |> Map.new(&{&1.account_id, &1})
  end

  ## Shared plumbing

  defp edge_attrs(attrs, account_id, target_account_id) do
    attrs
    |> Map.new()
    |> Map.put(:account_id, account_id)
    |> Map.put(:target_account_id, target_account_id)
  end

  defp get_edge(schema, %Account{id: id}, target), do: get_edge(schema, id, target)
  defp get_edge(schema, account_id, %Account{id: id}), do: get_edge(schema, account_id, id)

  defp get_edge(schema, account_id, target_id) do
    Repo.get_by(schema, account_id: account_id, target_account_id: target_id)
  end

  defp delete_edge(schema, %Account{id: id}, target), do: delete_edge(schema, id, target)
  defp delete_edge(schema, account_id, %Account{id: id}), do: delete_edge(schema, account_id, id)

  defp delete_edge(schema, account_id, target_id) do
    schema
    |> where([e], e.account_id == ^account_id and e.target_account_id == ^target_id)
    |> Repo.delete_all()

    :ok
  end

  # Wherever a request stops being one without being answered: the asker took
  # it back, or a block tore it down. The `Undo` matters as much as the row,
  # because the other server is holding a pending request of its own and
  # nothing else tells it the question was withdrawn.
  defp withdraw_request(account_id, target_id) do
    case get_edge(FollowRequest, account_id, target_id) do
      nil ->
        :ok

      request ->
        Repo.delete(request)
        forget_request(request)
        Outbox.unfollowed(request)

        :ok
    end
  end

  defp blocked_either_way?(account_id, target_id) do
    Block
    |> where(
      [b],
      (b.account_id == ^account_id and b.target_account_id == ^target_id) or
        (b.account_id == ^target_id and b.target_account_id == ^account_id)
    )
    |> Repo.exists?()
  end

  ## Lists a client shows

  @doc """
  Who this account has blocked, newest first.
  """
  @spec blocked_accounts(Account.t() | integer(), map()) :: [Account.t()]
  def blocked_accounts(account, page \\ %{}), do: edge_targets_query(Block, account, page)

  @doc """
  Who this account has muted, newest first. Expired mutes are not mutes.
  """
  @spec muted_accounts(Account.t() | integer(), map()) :: [Account.t()]
  def muted_accounts(account, page \\ %{}) do
    now = DateTime.utc_now()

    Mute
    |> where([m], is_nil(m.expires_at) or m.expires_at > ^now)
    |> edge_targets_query(account, page)
  end

  # `nil` for an account with no mute and for one whose mute has run out, so
  # the wire field means "this mute ends" rather than "there is a mute".
  defp mute_expiry(nil), do: nil

  defp mute_expiry(%Mute{} = mute) do
    if Mute.active?(mute), do: mute.expires_at
  end

  @doc """
  When each of `other_ids` stops being muted, for the ones that stop.

  Read alongside the accounts on the mutes page rather than from them: the
  expiry belongs to the mute, and an account entity has no idea it is being
  rendered as somebody's mute.
  """
  @spec mute_expiries(Account.t() | integer(), [integer()]) :: %{integer() => DateTime.t()}
  def mute_expiries(%Account{id: id}, other_ids), do: mute_expiries(id, other_ids)
  def mute_expiries(_account_id, []), do: %{}

  def mute_expiries(account_id, other_ids) do
    now = DateTime.utc_now()

    from(m in Mute,
      where:
        m.account_id == ^account_id and m.target_account_id in ^other_ids and
          not is_nil(m.expires_at) and m.expires_at > ^now,
      select: {m.target_account_id, m.expires_at}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Which domains this account has blocked.
  """
  @spec blocked_domains(Account.t() | integer(), map()) :: [String.t()]
  def blocked_domains(account, page \\ %{})
  def blocked_domains(%Account{id: id}, page), do: blocked_domains(id, page)

  def blocked_domains(account_id, page) do
    DomainBlock
    |> where([d], d.account_id == ^account_id)
    |> order_by([d], desc: d.id)
    |> limit(^Map.get(page, :limit, 100))
    |> select([d], d.domain)
    |> Repo.all()
  end

  @doc """
  Who is waiting for this account to let them follow.
  """
  @spec pending_followers(Account.t() | integer(), map()) :: [Account.t()]
  def pending_followers(account, page \\ %{})
  def pending_followers(%Account{id: id}, page), do: pending_followers(id, page)

  def pending_followers(account_id, page) do
    FollowRequest
    |> join(:inner, [r], a in Account, on: a.id == r.account_id)
    |> where([r], r.target_account_id == ^account_id)
    |> paginate_by_account(nil, page, :account_id)
  end

  @doc """
  How many people are waiting on this account to answer.

  Counted rather than listed because the navigation draws the entry only while
  the number is above zero, and it asks on every render of every page: a list
  of a hundred accounts to find out whether there is one is a hundred rows
  loaded to render a badge.
  """
  @spec pending_follower_count(Account.t() | integer()) :: non_neg_integer()
  def pending_follower_count(%Account{id: id}), do: pending_follower_count(id)

  def pending_follower_count(account_id) do
    FollowRequest
    |> where([r], r.target_account_id == ^account_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Accepts every follow request waiting on this account.

  For the morning after a move. Every follower's server acts on the `Move` at
  once, so an account that approves followers by hand wakes up to a thousand
  requests it already agreed to years ago — asking somebody to click through
  that is asking them not to bother.

  Returns how many were accepted.
  """
  @spec accept_all_follow_requests(Account.t() | integer()) :: non_neg_integer()
  def accept_all_follow_requests(%Account{id: id}), do: accept_all_follow_requests(id)

  def accept_all_follow_requests(account_id) do
    FollowRequest
    |> where([r], r.target_account_id == ^account_id)
    |> Repo.all()
    |> Enum.count(&match?({:ok, _follow}, accept_follow_request(&1)))
  end

  @doc """
  This account's followers, newest first, as `viewer` may see them.

  `viewer` is positional and required, the shape `Abuuba.Statuses` uses for
  every read that answers to somebody. It was an optional key inside the
  pagination map, which meant the filter was a no-op unless a caller
  remembered to fill it in: the REST endpoint did, and the profile page
  showing the same list did not, so blocking somebody hid them from an app
  and left them in the browser.

  `nil` for a list nobody is reading on their own behalf -- an export, or the
  federation side, which wants the edges themselves.
  """
  @spec followers(Account.t() | integer(), Account.t() | integer() | nil, map()) :: [Account.t()]
  def followers(account, viewer, page \\ %{})
  def followers(%Account{id: id}, viewer, page), do: followers(id, viewer, page)

  def followers(account_id, viewer, page) do
    Follow
    |> join(:inner, [f], a in Account, on: a.id == f.account_id)
    |> where([f], f.target_account_id == ^account_id)
    |> paginate_by_account(viewer, page, :account_id)
  end

  @doc """
  Who this account follows, newest first, as `viewer` may see them.

  Same shape and the same rule as `followers/3`.
  """
  @spec following(Account.t() | integer(), Account.t() | integer() | nil, map()) :: [Account.t()]
  def following(account, viewer, page \\ %{}),
    do: edge_targets(Follow, account, viewer, page)

  @doc """
  Removes somebody from this account's followers without blocking them.

  A quieter tool than a block: the follower is simply no longer following, and
  nothing tells them why. A block would also stop them reading anything at all,
  which is a different and much louder thing to do to somebody.
  """
  @spec remove_follower(Account.t() | integer(), Account.t() | integer()) :: :ok
  def remove_follower(account, follower), do: delete_edge(Follow, follower, account)

  @doc """
  People followed by those you follow, which is the useful answer to "who is
  this stranger, and does anybody I trust know them?".
  """
  @spec familiar_followers(Account.t() | integer(), [integer()]) :: [{integer(), [Account.t()]}]
  def familiar_followers(%Account{id: id}, target_ids), do: familiar_followers(id, target_ids)

  def familiar_followers(account_id, target_ids) do
    mine = following_ids(account_id)

    answers = if mine == [], do: %{}, else: familiar_by_target(mine, target_ids)

    Enum.map(target_ids, fn target_id -> {target_id, Map.get(answers, target_id, [])} end)
  end

  # The top five per target in one ranked query rather than one query per
  # target: a client asks about a whole page of accounts at once.
  defp familiar_by_target(mine, target_ids) do
    ranked =
      from f in Follow,
        where: f.target_account_id in ^target_ids and f.account_id in ^mine,
        windows: [per_target: [partition_by: f.target_account_id, order_by: [desc: f.account_id]]],
        select: %{
          target_id: f.target_account_id,
          account_id: f.account_id,
          rank: over(row_number(), :per_target)
        }

    rows =
      from(r in subquery(ranked), where: r.rank <= 5, order_by: [asc: r.target_id, asc: r.rank])
      |> Repo.all()

    accounts =
      Account
      |> where([a], a.id in ^Enum.map(rows, & &1.account_id))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    rows
    |> Enum.group_by(& &1.target_id)
    |> Map.new(fn {target_id, entries} ->
      {target_id, Enum.flat_map(entries, &List.wrap(accounts[&1.account_id]))}
    end)
  end

  defp edge_targets(schema, account, viewer, page),
    do: edge_targets_query(schema, account, viewer, page)

  defp edge_targets_query(schema, account, page),
    do: edge_targets_query(schema, account, nil, page)

  defp edge_targets_query(schema, %Account{id: id}, viewer, page),
    do: edge_targets_query(schema, id, viewer, page)

  defp edge_targets_query(schema, account_id, viewer, page) do
    schema
    |> join(:inner, [e], a in Account, on: a.id == e.target_account_id)
    |> where([e], e.account_id == ^account_id)
    |> paginate_by_account(viewer, page, :target_account_id)
  end

  # Paged on the account id, because that is the id a client gets back and
  # the one it will send in the next request. The window sits on the edge
  # table's copy of it — equal to `a.id` by the join, but only the edge
  # column is in the index that serves the scan, and Postgres never pushes an
  # inequality through a join.
  defp paginate_by_account(query, viewer, page, cursor_field) do
    query
    |> exclude_hidden_from(viewer)
    |> maybe_older_than(Map.get(page, :max_id), cursor_field)
    |> maybe_newer_than(Map.get(page, :min_id) || Map.get(page, :since_id), cursor_field)
    |> order_by([e, _a], [{^Pagination.direction(page), field(e, ^cursor_field)}])
    |> limit(^Map.get(page, :limit, 40))
    |> select([_e, a], a)
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  # A list of people is still a list of people the reader has opinions about,
  # and somebody they blocked, muted, or shut a whole server out over does not
  # belong on it. `nil` for a list nobody is reading on their own behalf.
  #
  # The domain was missing while the other two were here, which is the shape
  # this file keeps producing: a rule written down where somebody was looking
  # and nowhere else.
  defp exclude_hidden_from(query, nil), do: query

  defp exclude_hidden_from(query, %Account{id: viewer_id}),
    do: exclude_hidden_from(query, viewer_id)

  defp exclude_hidden_from(query, viewer_id) do
    query
    |> where([_e, a], a.id not in subquery(edge_targets_of(Block, viewer_id)))
    |> where([_e, a], a.id not in subquery(edge_targets_of(Mute, viewer_id)))
    |> where([_e, a], is_nil(a.domain) or a.domain not in subquery(blocked_domains_of(viewer_id)))
  end

  defp blocked_domains_of(account_id) do
    from(d in DomainBlock, where: d.account_id == ^account_id, select: d.domain)
  end

  defp edge_targets_of(schema, account_id) do
    from(e in schema, where: e.account_id == ^account_id, select: e.target_account_id)
  end

  defp maybe_older_than(query, nil, _cursor_field), do: query

  defp maybe_older_than(query, id, cursor_field),
    do: where(query, [e, _a], field(e, ^cursor_field) < ^id)

  defp maybe_newer_than(query, nil, _cursor_field), do: query

  defp maybe_newer_than(query, id, cursor_field),
    do: where(query, [e, _a], field(e, ^cursor_field) > ^id)
end

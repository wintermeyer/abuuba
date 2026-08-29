defmodule Abuuba.Federation.Outbox do
  @moduledoc """
  The one place a thing somebody does here becomes an activity other servers
  receive.

  `Abuuba.Federation.Serializer` knows what each activity looks like and
  `Abuuba.Federation.Delivery` knows how to get one to a few hundred inboxes
  without a dead server holding up the rest. Neither knows *when*. That is this
  module, and it exists because for a while nothing did: both halves were built
  and tested, no context called one with the output of the other, and an abuuba
  instance received federation while publishing none of its own.

  One function per thing a person can do, named after the doing rather than
  after the activity, so a context calls `status_created/1` and never has to
  know that a boost's withdrawal is an `Undo` of an `Announce` while a post's
  is a `Delete`.

  ## Two shapes of audience

  Something an account **published** goes to everybody who follows it, everybody
  it names, and the relays: a post, an edit, a deletion, a boost, a pin, a
  changed profile. `Abuuba.Federation.Delivery.distribute/3` works that list out.

  Something an account did **to one other account** goes to that account and
  nobody else: a follow, its acceptance, a favourite, a block. A block in
  particular must not be broadcast; the blocker never chose to publish it, and
  a peer that saw it in a public audience would have learned something private.

  ## Nothing that is not ours

  Every entry point refuses an account or a post that belongs to another
  server. Republishing somebody else's post under our own delivery is how the
  same object loops around the network with two servers claiming it.

  ## Undo is built from what was sent

  An `Undo` has to name the id the peer stored, which is the id we sent, not
  anything the row can be asked for after the fact. So the withdrawals here
  take the row *before* it is deleted, render what was originally sent, and
  wrap that. A context that deletes first has nothing left to undo with.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Delivery
  alias Abuuba.Federation.Serializer
  alias Abuuba.Relationships.Block
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.FollowRequest
  alias Abuuba.Repo
  alias Abuuba.Statuses.Favourite
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag

  ## Posts

  @doc """
  A new post reaches the people its author's followers are.

  A boost is a post locally and an `Announce` on the wire. It carries no words
  of its own, so a `Create` for it would publish an empty note where a peer
  expects to be told that somebody else's post was passed on.
  """
  @spec status_created(Status.t()) :: :ok
  def status_created(%Status{reblog_of_id: nil} = status),
    do: publish(status, &Serializer.create/1)

  def status_created(%Status{} = boost), do: publish(boost, &Serializer.announce/1)

  @doc """
  An edit, so a peer stops showing words that were changed.
  """
  @spec status_edited(Status.t()) :: :ok
  def status_edited(%Status{} = status), do: publish(status, &Serializer.update/1)

  @doc """
  A deletion, or the post goes on existing everywhere but here.

  A boost is withdrawn rather than deleted. The two are the same row locally
  and different activities on the wire: a peer that received our `Announce`
  is holding a boost of somebody else's post, and what we are taking back is
  the announcement, not their post.
  """
  @spec status_deleted(Status.t()) :: :ok
  def status_deleted(%Status{reblog_of_id: nil} = status),
    do: publish(status, &Serializer.delete/1)

  def status_deleted(%Status{} = boost),
    do: publish(boost, &Serializer.undo(Serializer.announce(&1)))

  ## One account to another

  @doc """
  A favourite, which is news only for the person who wrote the post.
  """
  @spec favourited(Favourite.t()) :: :ok
  def favourited(%Favourite{} = favourite) do
    send_one(favourite.account_id, author_of_status(favourite.status_id), &Serializer.like(&1),
      subject: favourite
    )
  end

  @doc """
  Taking a favourite back. Called before the row goes, so there is still
  something to name.
  """
  @spec unfavourited(Favourite.t()) :: :ok
  def unfavourited(%Favourite{} = favourite) do
    send_one(
      favourite.account_id,
      author_of_status(favourite.status_id),
      &(&1 |> Serializer.like() |> Serializer.undo()),
      subject: favourite
    )
  end

  @doc """
  A follow, or a request to follow an account that approves its followers.
  Both are the same activity; whether it is granted is the other server's call.
  """
  @spec followed(Follow.t() | FollowRequest.t()) :: :ok
  def followed(edge) do
    send_one(edge.account_id, edge.target_account_id, &Serializer.follow/1, subject: edge)
  end

  @doc """
  Withdrawing a follow. Called before the row goes.
  """
  @spec unfollowed(Follow.t() | FollowRequest.t()) :: :ok
  def unfollowed(edge) do
    send_one(
      edge.account_id,
      edge.target_account_id,
      &(&1 |> Serializer.follow() |> Serializer.undo()),
      subject: edge
    )
  end

  @doc """
  Granting a request. Sent by the account that was asked, to the one that asked.
  """
  @spec follow_accepted(FollowRequest.t()) :: :ok
  def follow_accepted(%FollowRequest{} = request) do
    send_one(request.target_account_id, request.account_id, &Serializer.accept/1,
      subject: request
    )
  end

  @doc """
  Turning one down, rather than leaving the asker waiting forever.
  """
  @spec follow_rejected(FollowRequest.t()) :: :ok
  def follow_rejected(%FollowRequest{} = request) do
    send_one(request.target_account_id, request.account_id, &Serializer.reject/1,
      subject: request
    )
  end

  @doc """
  A vote on somebody else's poll, sent to the server that owns it.

  One activity per option chosen, because that is how a multiple-choice vote
  travels: there is no way to say "these three" in a single one.

  A vote on one of our own polls sends nothing -- there is nobody to tell.
  `send_one/4` already refuses a local target, so that needs no check here.
  """
  @spec voted(Poll.t(), Account.t(), [non_neg_integer()]) :: :ok
  def voted(%Poll{} = poll, %Account{} = voter, choices) do
    Enum.each(choices, fn choice ->
      send_one(voter.id, poll.account_id, &Serializer.vote(&1, voter, choice), subject: poll)
    end)
  end

  @doc """
  A block, so the other server stops delivering to somebody who does not want it.
  """
  @spec blocked(Block.t()) :: :ok
  def blocked(%Block{} = block) do
    send_one(block.account_id, block.target_account_id, &Serializer.block/1, subject: block)
  end

  @doc """
  Lifting a block. Called before the row goes.
  """
  @spec unblocked(Block.t()) :: :ok
  def unblocked(%Block{} = block) do
    send_one(
      block.account_id,
      block.target_account_id,
      &(&1 |> Serializer.block() |> Serializer.undo()),
      subject: block
    )
  end

  ## Profiles and pins

  @doc """
  A changed profile, so peers stop showing the old name, note or avatar.
  """
  @spec profile_updated(Account.t()) :: :ok
  def profile_updated(%Account{domain: nil} = account) do
    Delivery.distribute(account, Serializer.update_actor(account))
  end

  def profile_updated(%Account{}), do: :ok

  @doc """
  Pinning a post, which is an `Add` to the collection peers read off a profile.
  """
  @spec pinned(Account.t(), Status.t()) :: :ok
  def pinned(account, status), do: featured(account, status, &Serializer.add/2)

  @doc """
  Unpinning it again.
  """
  @spec unpinned(Account.t(), Status.t()) :: :ok
  def unpinned(account, status), do: featured(account, status, &Serializer.remove/2)

  @doc """
  Featuring a hashtag, which peers read off the same collection as a pinned post.
  """
  @spec tag_featured(Account.t(), Tag.t()) :: :ok
  def tag_featured(account, tag), do: featured(account, tag, &Serializer.add_tag/2)

  @doc """
  Taking it back off.
  """
  @spec tag_unfeatured(Account.t(), Tag.t()) :: :ok
  def tag_unfeatured(account, tag), do: featured(account, tag, &Serializer.remove_tag/2)

  ## Plumbing

  # A post or a hashtag: both are things an account adds to the one collection
  # peers read off its profile, and the only difference is what the serializer
  # makes of the subject. Only ever for an account that lives here.
  defp featured(%Account{domain: nil} = account, subject, build) do
    Delivery.distribute(account, build.(account, subject))
  end

  defp featured(_account, _subject, _build), do: :ok

  # Only what started here, and only for an account that lives here.
  defp publish(%Status{local: false}, _build), do: :ok

  defp publish(%Status{} = status, build) do
    case Repo.get(Account, status.account_id) do
      %Account{domain: nil} = account ->
        Delivery.distribute(account, build.(status), status: status)

      _ ->
        :ok
    end
  end

  # An activity addressed to one account. Nothing is sent when either end is
  # here: two local accounts need no server in between, and an account that is
  # not ours has no business signing as us.
  defp send_one(_actor_id, nil, _build, _opts), do: :ok

  defp send_one(actor_id, target_id, build, subject: subject) do
    with %Account{domain: nil} = actor <- Repo.get(Account, actor_id),
         %Account{domain: domain} = target when not is_nil(domain) <-
           Repo.get(Account, target_id) do
      Delivery.deliver_to_account(target, build.(subject), actor)
    else
      _ -> :ok
    end
  end

  defp author_of_status(status_id) do
    case Repo.get(Status, status_id) do
      %Status{account_id: account_id} -> account_id
      nil -> nil
    end
  end
end

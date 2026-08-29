defmodule Abuuba.Timelines.FanOut do
  @moduledoc """
  Deciding whose feeds a post belongs in, and writing it there.

  ## Chunks, not one job per follower

  The reference implementation enqueues a job per follower. Twenty thousand
  followers is twenty thousand jobs, each of which loads that follower's
  blocks, mutes and follow settings for itself. Here it is one job per five
  hundred, each loading the filter data for its whole chunk in a handful of
  queries and finishing with one bulk insert. Forty jobs and eighty round trips
  rather than twenty thousand of each.

  ## Small posts never touch the queue

  Most posts reach a handful of people, and a job round trip to write three
  rows is pure overhead. One chunk's worth is done inline; past that it goes to
  the queue so the person posting is not waiting on it.

  ## The author is first, always

  Their own feed is written before anything else, inline, before any job
  exists. A post that takes a second to appear in your own timeline reads as a
  post that failed.

  ## Dormant accounts are skipped

  A feed written for somebody who has not opened the place in months is rows
  nobody will read, and the work of writing them is paid on every post by
  everybody they follow. A remote follower has no user row at all and is never
  dormant: they are not reading this table, they are being delivered to.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 5

  import Ecto.Query

  alias Abuuba.Accounts.User
  alias Abuuba.Lists
  alias Abuuba.Notifications
  alias Abuuba.Relationships.Block
  alias Abuuba.Relationships.DomainBlock
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.Mute
  alias Abuuba.Repo
  alias Abuuba.Statuses.ConversationMute
  alias Abuuba.Statuses.Status
  alias Abuuba.Timelines.Feed

  # Big enough that a large audience is tens of jobs rather than thousands,
  # small enough that one job's filter data fits comfortably in memory and a
  # retry redoes little.
  @chunk_size 500

  # How recently somebody has to have signed in to count as reading their feed.
  @active_days 7

  @doc """
  How many followers one job handles.
  """
  @spec chunk_size() :: pos_integer()
  def chunk_size, do: @chunk_size

  @doc """
  Puts a post into every feed it belongs in.

  Called for local posts as they are made and for remote ones as they arrive.
  """
  @spec deliver(Status.t()) :: :ok
  def deliver(%Status{} = status) do
    own_feed(status)

    case status |> audience() |> Enum.chunk_every(@chunk_size) do
      [] ->
        :ok

      [first | rest] ->
        # The first chunk now, the rest on the queue. All of it inline would
        # make posting take as long as somebody's audience is large; all of it
        # queued would make a post to three people wait on a job runner.
        write(status, first)

        Enum.each(rest, &enqueue(status, &1))
    end

    write_tag_followers(status)

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"status_id" => status_id, "accounts" => account_ids}}) do
    case Repo.get(Status, status_id) do
      # Deleted between the post and the job, which is ordinary rather than a
      # fault: somebody changed their mind.
      nil -> :ok
      status -> write(status, account_ids)
    end
  end

  ## Choosing

  # Their own feed, inline and first. Not subject to any of the filtering
  # below: nobody blocks, mutes or language-filters themselves.
  #
  # Only for an author here. A home feed is what somebody sees when they open
  # this server as themselves, and somebody on another server cannot do that —
  # so a row for them is one per remote post in the second-largest table that
  # nothing will ever read.
  defp own_feed(%Status{local: true, account_id: account_id, id: id}) do
    Feed.insert("home", account_id, id)
  end

  defp own_feed(%Status{}), do: :ok

  # Everybody who might want this: the author's followers, minus the author,
  # minus anybody who has stopped reading. The per-person rules are applied in
  # the chunk, where their data is loaded once for five hundred people at a
  # time.
  # A direct message goes to the people it names, not to the author's
  # followers. It reaches them through the conversation inbox
  # (`Abuuba.Conversations`), which is where a client reads them, and following
  # somebody is not an invitation to read their messages to other people.
  defp audience(%Status{visibility: :direct}), do: []

  defp audience(%Status{account_id: account_id}) do
    dormant = DateTime.add(DateTime.utc_now(), -@active_days, :day)

    Follow
    |> where([f], f.target_account_id == ^account_id)
    |> where([f], f.account_id != ^account_id)
    |> join(:left, [f], u in User, on: u.account_id == f.account_id)
    |> where(
      [f, u],
      is_nil(u.id) or is_nil(u.last_signed_in_at) or u.last_signed_in_at > ^dormant
    )
    |> select([f], f.account_id)
    |> Repo.all()
  end

  defp enqueue(status, accounts) do
    %{status_id: status.id, accounts: accounts} |> new() |> Oban.insert()
  end

  ## Writing

  defp write(status, account_ids) do
    context = load(status, account_ids)

    wanted = Enum.filter(account_ids, &wants?(&1, status, context))

    Enum.each(wanted, &place(status, &1))
    Enum.each(wanted, &maybe_announce(status, &1, context))

    write_lists(status, account_ids)

    :ok
  end

  # "Tell me when this person posts", for the people who asked. Only for those
  # who are getting the post anyway, so it inherits every reason a post is kept
  # from somebody: a blocked author, a muted thread, the wrong language.
  #
  # Not a boost and not an edit: the bell is for what this person says, not for
  # everything they pass on or for a typo they fixed. Not a reply either,
  # unless it answers their own post — that is somebody continuing a thread,
  # which is the thing you asked to be told about, where a reply to a stranger
  # is a conversation you did not.
  #
  # A direct message is left alone because it arrives as a mention, and two
  # notifications for one post is worse than the wrong one.
  defp maybe_announce(status, account_id, context) do
    if announceable?(status) and notifying?(context, account_id) do
      Notifications.notify(account_id, status.account_id, "status", status_id: status.id)
    end

    :ok
  end

  defp announceable?(%Status{reblog_of_id: id}) when not is_nil(id), do: false
  defp announceable?(%Status{visibility: :direct}), do: false
  defp announceable?(%Status{in_reply_to_id: nil}), do: true

  defp announceable?(%Status{} = status),
    do: status.in_reply_to_account_id == status.account_id

  defp notifying?(context, account_id) do
    match?(%{notify: true}, Map.get(context.follows, account_id))
  end

  # A boost stands behind whatever is already showing the same words. The
  # original itself counts: somebody who follows the author and the booster has
  # already read it, and a second copy underneath is a second copy.
  defp place(%Status{reblog_of_id: nil} = status, account_id) do
    Feed.insert("home", account_id, status.id)
  end

  defp place(%Status{reblog_of_id: original_id} = status, account_id) do
    case Feed.showing("home", account_id, [original_id | boost_ids(original_id)]) do
      nil -> Feed.insert("home", account_id, status.id)
      shown -> Feed.insert_hidden("home", account_id, status.id, shown)
    end
  end

  defp boost_ids(original_id) do
    from(s in Status,
      where: s.reblog_of_id == ^original_id and is_nil(s.deleted_at),
      select: s.id
    )
    |> Repo.all()
  end

  # Everything the per-person rules need, in a handful of queries for the whole
  # chunk. This is the difference the design is built on: the same data loaded
  # once for five hundred people rather than five hundred times.
  defp load(status, account_ids) do
    now = DateTime.utc_now()
    author = status.account_id

    %{
      blocking:
        set(
          from(b in Block,
            where: b.account_id in ^account_ids and b.target_account_id == ^author,
            select: b.account_id
          )
        ),
      blocked_by:
        set(
          from(b in Block,
            where: b.target_account_id in ^account_ids and b.account_id == ^author,
            select: b.target_account_id
          )
        ),
      muting:
        set(
          from(m in Mute,
            where:
              m.account_id in ^account_ids and m.target_account_id == ^author and
                (is_nil(m.expires_at) or m.expires_at > ^now),
            select: m.account_id
          )
        ),
      domain_blocking: domain_blockers(status, account_ids),
      exclusive: exclusive_holders(author, account_ids),
      thread_muting: thread_muters(status, account_ids),
      follows: follows(author, account_ids),
      following_replied_to: following_replied_to(status, account_ids)
    }
  end

  defp wants?(account_id, status, context) do
    not MapSet.member?(context.blocking, account_id) and
      not MapSet.member?(context.blocked_by, account_id) and
      not MapSet.member?(context.muting, account_id) and
      not MapSet.member?(context.domain_blocking, account_id) and
      not MapSet.member?(context.exclusive, account_id) and
      not MapSet.member?(context.thread_muting, account_id) and
      allowed_by_follow?(status, Map.get(context.follows, account_id)) and
      reply_wanted?(status, account_id, context)
  end

  # A boost somebody asked not to see, or a language they did not ask for. A
  # post with no language set passes: most posts carry none, and filtering them
  # would empty the timeline of somebody who meant "not the other one".
  defp allowed_by_follow?(_status, nil), do: true

  defp allowed_by_follow?(%Status{reblog_of_id: id}, %{show_reblogs: false}) when not is_nil(id),
    do: false

  defp allowed_by_follow?(%Status{language: language}, %{languages: [_ | _] = languages})
       when is_binary(language),
       do: language in languages

  defp allowed_by_follow?(_status, _follow), do: true

  # A reply is only wanted by somebody who can see both sides. Following one
  # person otherwise fills a timeline with half of conversations.
  defp reply_wanted?(%Status{in_reply_to_id: nil}, _account_id, _context), do: true

  defp reply_wanted?(%Status{} = status, account_id, context) do
    status.in_reply_to_account_id in [nil, status.account_id, account_id] or
      MapSet.member?(context.following_replied_to, account_id)
  end

  ## The per-chunk lookups

  defp domain_blockers(%Status{local: true}, _account_ids), do: MapSet.new()

  defp domain_blockers(status, account_ids) do
    case author_domain(status) do
      nil ->
        MapSet.new()

      domain ->
        set(
          from(d in DomainBlock,
            where: d.account_id in ^account_ids and d.domain == ^domain,
            select: d.account_id
          )
        )
    end
  end

  defp author_domain(%Status{account_id: account_id}) do
    from(a in "accounts", where: a.id == ^account_id, select: a.domain) |> Repo.one()
  end

  defp exclusive_holders(author_id, account_ids) do
    account_ids
    |> Enum.filter(&(author_id in Lists.exclusive_member_ids(&1)))
    |> MapSet.new()
  end

  defp thread_muters(%Status{conversation_id: nil}, _account_ids), do: MapSet.new()

  defp thread_muters(%Status{conversation_id: conversation_id}, account_ids) do
    set(
      from(c in ConversationMute,
        where: c.account_id in ^account_ids and c.conversation_id == ^conversation_id,
        select: c.account_id
      )
    )
  end

  defp follows(author_id, account_ids) do
    Follow
    |> where([f], f.account_id in ^account_ids and f.target_account_id == ^author_id)
    |> select(
      [f],
      {f.account_id, %{show_reblogs: f.show_reblogs, languages: f.languages, notify: f.notify}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp following_replied_to(%Status{in_reply_to_account_id: nil}, _account_ids), do: MapSet.new()

  defp following_replied_to(%Status{in_reply_to_account_id: target}, account_ids) do
    set(
      from(f in Follow,
        where: f.account_id in ^account_ids and f.target_account_id == ^target,
        select: f.account_id
      )
    )
  end

  ## Lists

  # A list is a second feed with the same rules about who wrote the post and
  # none about who follows whom: membership is the whole of it.
  # A followed hashtag puts a post in a home feed for somebody who follows
  # nobody in it. Only public posts: a followers-only post carrying a hashtag
  # was still made to followers, and following a tag is not following a person.
  defp write_tag_followers(%Status{visibility: v} = status) when v in [:public, :unlisted] do
    readers =
      from(t in "statuses_tags",
        join: f in "tag_follows",
        on: f.tag_id == t.tag_id,
        where: t.status_id == ^status.id,
        select: f.account_id,
        distinct: true
      )
      |> Repo.all()

    readers
    |> Enum.map(&%{feed_type: "home", feed_id: &1, status_id: status.id})
    |> Feed.insert_many()
  end

  defp write_tag_followers(_status), do: :ok

  defp write_lists(status, account_ids) do
    lists = Lists.lists_containing(status.account_id, account_ids)

    rows =
      lists
      |> keep_by_replies_policy(status)
      |> Enum.map(&%{feed_type: "list", feed_id: &1.id, status_id: status.id})

    Feed.insert_many(rows)
  end

  # What a list's `replies_policy` decides. It was stored, importable and
  # documented, and nothing applied it -- so a list set to hide replies showed
  # them, which is the first thing somebody does to a noisy list.
  #
  # A post that is not a reply belongs in every list its author is in, whatever
  # the policy says: the policy is about replies and nothing else. A reply
  # whose parent has gone counts as one of those, because there is no longer
  # anybody it can be judged against.
  defp keep_by_replies_policy(lists, %Status{in_reply_to_account_id: nil}), do: lists

  defp keep_by_replies_policy([], _status), do: []

  defp keep_by_replies_policy(lists, %Status{in_reply_to_account_id: parent_author_id}) do
    # Both lookups are one query for all the candidate lists rather than one
    # per list.
    member_of = Lists.list_ids_with_member(Enum.map(lists, & &1.id), parent_author_id)
    followed_by = owners_following(lists, parent_author_id)

    Enum.filter(lists, fn list ->
      case list.replies_policy do
        "none" -> false
        "followed" -> MapSet.member?(followed_by, list.account_id)
        _list -> MapSet.member?(member_of, list.id)
      end
    end)
  end

  defp owners_following(lists, parent_author_id) do
    owner_ids =
      for %{replies_policy: "followed", account_id: owner_id} <- lists, uniq: true, do: owner_id

    if owner_ids == [] do
      MapSet.new()
    else
      Follow
      |> where([f], f.account_id in ^owner_ids and f.target_account_id == ^parent_author_id)
      |> select([f], f.account_id)
      |> Repo.all()
      |> MapSet.new()
    end
  end

  defp set(query), do: query |> Repo.all() |> MapSet.new()
end

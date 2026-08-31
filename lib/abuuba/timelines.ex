defmodule Abuuba.Timelines do
  @moduledoc """
  What a reader sees, and where they had got to.

  ## Computed rather than stored, for now

  The home timeline is built by querying who somebody follows. That is the
  honest thing to do while there is no feed table: a materialised feed is
  issue #44, and writing half of one here would leave two ways of answering
  the same question that could disagree.

  It is also fast enough at this size. The query is an index scan over the
  follow set, and the cost only becomes interesting when one account follows
  thousands of people who post constantly.

  ## Every timeline filters for the reader

  Not one of these composes `Abuuba.Statuses.not_deleted/0` on its own. A
  timeline is exactly where somebody else's followers-only post sits next to
  public ones, so every query here goes through `visible_to/2` as well.

  ## And answers `timeline_access` itself

  Whether a server shows its public timelines to strangers at all was a
  caller-side `if` at seven sites in four shapes, and the shapes disagreed:
  explore gated the recent half and not the trending half, and what was
  trending answered anybody. A rule spelled out by each caller is a rule each
  new caller may forget, and the ones that forgot were the surfaces nobody
  thought of as a timeline.

  So `public/2` and `tag/3` answer it themselves and hand back nothing when
  the setting says so, and `Abuuba.Trends.statuses/2` does the same for the
  third of these lists. Two copies are left on purpose:
  `AbuubaWeb.API.TimelineController`, because it has to say *which* refusal it
  is -- 404 for a server that has turned them off, 422 for one that wants an
  account -- and an empty list cannot carry that; and the two streaming
  transports, which answer it when a socket subscribes rather than per post.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Lists
  alias Abuuba.Lists.List, as: AccountList
  alias Abuuba.Pagination
  alias Abuuba.Relationships.Follow
  alias Abuuba.Repo
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag
  alias Abuuba.Timelines.Feed
  alias Abuuba.Timelines.Marker

  @doc """
  Posts by the people somebody follows, plus their own.

  Their own included, because a timeline that does not show you what you just
  said reads as though the post failed.
  """
  @spec home(Account.t(), map()) :: [Status.t()]
  def home(%Account{id: account_id} = account, page \\ %{}) do
    # Read from the feed rather than derived from the follow graph. Who wanted
    # this post was decided once when it was written; see
    # `Abuuba.Timelines.FanOut`. The visibility check stays, because a post's
    # audience can narrow after it was fanned out.
    "home"
    |> Feed.status_ids(account_id, page)
    |> load_statuses(account, page)
  end

  @doc """
  Statuses by id, in the order the ids were given, narrowed to what this
  reader may be shown.

  The ids come from the trends table, which ranked them knowing nothing about
  who is reading. This is the step that asks, and the reason a ranking cannot
  become a way around a block.
  """
  @spec by_ids([integer() | String.t()], Account.t() | nil) :: [Status.t()]
  def by_ids(ids, viewer) do
    Statuses.not_deleted()
    |> Statuses.visible_to(viewer)
    |> exclude_unwanted(viewer)
    # A ranking is written once and never revisited, so a moderator silencing
    # somebody afterwards does not take their post out of it. Both other reads
    # here drop those authors; this one has to as well, or a silence is a
    # thing every timeline honours except the most prominent list on the
    # server.
    |> exclude_moderated_authors()
    |> then(&Statuses.by_ids(ids, &1))
  end

  # In the feed's order, which is the order the ids came back in, rather than
  # whatever order the database returns rows in.
  defp load_statuses([], _account, _page), do: []

  defp load_statuses(ids, account, page) do
    # The feed says who a post reached, decided once when it was written.
    # This says what the reader wants right now: a mute, a thread mute or a
    # block can arrive after the post did, and all three are reversible, so
    # they are read-time questions rather than reasons to rewrite a feed.
    by_id =
      Statuses.not_deleted()
      |> Statuses.visible_to(account)
      |> where([s], s.id in ^ids)
      |> exclude_unwanted(account)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    ids
    |> Enum.flat_map(&List.wrap(by_id[&1]))
    |> Pagination.reading_order(page)
  end

  @doc """
  Everything public this server can see.

  `local` restricts it to posts written here, `remote` to posts from anywhere
  else, and `only_media` to posts carrying an attachment.
  """
  @spec public(Account.t() | nil, map()) :: [Status.t()]
  def public(viewer, page \\ %{}) do
    if Settings.public_timelines_readable?(viewer) do
      # No `visible_to/2` on top: the scope already pins visibility to public,
      # which anybody may read, and restating it would only widen the query
      # away from the partial index the scope is written against.
      Statuses.public_timeline_scope()
      |> filter_origin(page)
      |> filter_media(page)
      |> exclude_unwanted(viewer)
      |> paginate(page)
    else
      []
    end
  end

  @doc """
  Posts under a hashtag, with the combinations a client offers.

  `any` widens, `all` narrows, and `none` excludes. Each is capped at four
  because the query cost is one join per tag and nothing renders more than
  that.
  """
  @spec tag(String.t(), Account.t() | nil, map()) :: [Status.t()]
  def tag(name, viewer, page \\ %{}) do
    if Settings.public_timelines_readable?(viewer) do
      tagged(name, viewer, page)
    else
      []
    end
  end

  defp tagged(name, viewer, page) do
    case tag_ids([name | Map.get(page, :any, [])]) do
      [] ->
        []

      any_ids ->
        Statuses.not_deleted()
        |> Statuses.visible_to(viewer)
        |> where([s], s.visibility in [:public, :unlisted])
        |> where([s], s.id in subquery(tagged_with_any(any_ids)))
        |> require_all(Map.get(page, :all, []))
        |> exclude_any(Map.get(page, :none, []))
        |> exclude_moderated_authors()
        |> filter_origin(page)
        |> filter_media(page)
        |> exclude_unwanted(viewer)
        |> paginate(page)
    end
  end

  @doc """
  How many tags a client may name in one of the three lists.
  """
  @spec max_tags() :: pos_integer()
  def max_tags, do: 4

  ## Filters

  # Blocks, mutes and muted threads, all in one place. A timeline that applied
  # only some of them would show somebody exactly what they asked not to see,
  # and which one leaked would depend on which endpoint they used.
  #
  # `NOT EXISTS` rather than `NOT IN (subquery)`: Postgres refuses to turn the
  # latter into an anti-join because of `NOT IN`'s null semantics, so it hashes
  # the reader's whole block list per page. The correlated probe is one lookup
  # in a unique index per candidate row, whatever the list has grown to. It
  # needs the `:status` named binding every statuses base query carries.
  defp exclude_unwanted(query, nil), do: query

  defp exclude_unwanted(query, %Account{id: account_id}) do
    # Blocks and mutes live in `Statuses.excluding_hidden/2` because search
    # needs the same answer and was giving a different one. A muted
    # conversation stays here: it is a thread somebody put down rather than a
    # person they will not deal with, and it is not something a search for a
    # word should hide.
    query
    |> Statuses.excluding_hidden(account_id)
    |> Statuses.excluding_muted_threads(account_id)
  end

  # The same authors the public timeline keeps out, for the reason written next
  # to `Statuses.public_timeline_scope/0`: a silence is a moderator saying "not
  # in front of strangers", and a hashtag timeline is a room of strangers too.
  # Only the authors, though -- replies and quiet-public posts belong on a tag
  # timeline in a way they do not belong in the firehose, which is why this is
  # a filter of its own rather than the public scope reused.
  defp exclude_moderated_authors(query) do
    where(
      query,
      [s],
      not exists(
        from(a in Account,
          where:
            a.id == parent_as(:status).account_id and
              (not is_nil(a.suspended_at) or not is_nil(a.silenced_at)),
          select: 1
        )
      )
    )
  end

  defp filter_origin(query, %{local: true}), do: where(query, [s], s.local)
  defp filter_origin(query, %{remote: true}), do: where(query, [s], not s.local)
  defp filter_origin(query, _page), do: query

  defp filter_media(query, %{only_media: true}) do
    where(query, [s], fragment("cardinality(?) > 0", s.ordered_media_attachment_ids))
  end

  defp filter_media(query, _page), do: query

  defp tagged_with_any(tag_ids) do
    from(st in "statuses_tags", where: st.tag_id in ^tag_ids, select: st.status_id)
  end

  # One `IN` per tag rather than one for the set: "all" means every one of
  # them, and a single `IN` would mean any of them.
  defp require_all(query, names) do
    names
    |> tag_ids()
    |> Enum.reduce(query, fn tag_id, acc ->
      where(acc, [s], s.id in subquery(tagged_with_any([tag_id])))
    end)
  end

  defp exclude_any(query, []), do: query

  defp exclude_any(query, names) do
    case tag_ids(names) do
      [] ->
        query

      ids ->
        where(
          query,
          [s],
          not exists(
            from st in "statuses_tags",
              where: st.status_id == parent_as(:status).id and st.tag_id in ^ids,
              select: st.status_id
          )
        )
    end
  end

  defp tag_ids(names) do
    normalised =
      names
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.take(max_tags())
      |> Enum.map(&Tag.normalise/1)
      |> Enum.reject(&(&1 == ""))

    if normalised == [] do
      []
    else
      Tag |> where([t], t.name in ^normalised) |> select([t], t.id) |> Repo.all()
    end
  end

  # The precedence this used to argue for in a comment now lives in
  # `Pagination.window/2`, which is where the disagreement was.
  defp paginate(query, page) do
    query
    |> Pagination.window(page)
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  @doc """
  What the people in one list said.
  """
  @spec list(AccountList.t(), Account.t(), map()) :: [Status.t()]
  def list(%AccountList{id: list_id}, %Account{} = viewer, page \\ %{}) do
    "list" |> Feed.status_ids(list_id, page) |> load_statuses(viewer, page)
  end

  ## Merging and unmerging

  # How far back a follow reaches. Enough that a new follow has something to
  # read immediately, far short of importing somebody's whole history into a
  # feed that is capped anyway.
  @backfill_limit 40

  @doc """
  How many of somebody's posts a new follow brings with it.
  """
  @spec backfill_limit() :: pos_integer()
  def backfill_limit, do: @backfill_limit

  @doc """
  Puts an account's recent posts into a reader's home feed.

  What a follow does to a feed that already exists. Following somebody and then
  seeing nothing until they post again is a follow that looks broken.

  The posts are filtered as the fan-out would have filtered them, because this
  is the same question asked later: everything the reader can see, minus what
  they have said they do not want.
  """
  @spec merge_account(Account.t() | integer(), Account.t() | integer()) :: :ok
  def merge_account(%Account{id: reader_id}, author), do: merge_account(reader_id, author)
  def merge_account(reader_id, %Account{id: author_id}), do: merge_account(reader_id, author_id)

  def merge_account(reader_id, author_id) do
    reader = Accounts.get_account(reader_id)

    Statuses.not_deleted()
    |> Statuses.visible_to(reader)
    |> where([s], s.account_id == ^author_id)
    |> exclude_unwanted(reader)
    |> exclude_unwanted_boosts(reader_id, author_id)
    |> order_by([s], desc: s.id)
    |> limit(@backfill_limit)
    |> select([s], s.id)
    |> Repo.all()
    |> Enum.map(&%{feed_type: "home", feed_id: reader_id, status_id: &1})
    |> Feed.insert_many()
  end

  @doc """
  Rebuilds one account's home feed from scratch.

  Not a fan-out in reverse: the fan-out asks "who wants this post" and this
  asks "what does this person want", which is the same filtering from the other
  end. So it goes through `merge_account/2` and `merge_tag/2` per followed
  account and followed tag rather than restating the rules, which is what keeps
  a rebuilt feed showing the same posts a live one would — blocks, mutes and
  boost preferences included.
  """
  @spec regenerate(Account.t() | integer()) :: :ok
  def regenerate(%Account{id: account_id}), do: regenerate(account_id)

  def regenerate(account_id) do
    # Their own posts first. A home timeline has always included them, and the
    # fan-out is what usually puts them there — which is no help to a feed
    # being built from nothing.
    Enum.each([account_id | followed_ids(account_id)], &merge_account(account_id, &1))

    account_id
    |> Statuses.followed_tags(%{limit: 100})
    |> Enum.each(&merge_tag(account_id, &1))
  end

  defp followed_ids(account_id) do
    Follow
    |> where([f], f.account_id == ^account_id)
    |> select([f], f.target_account_id)
    |> Repo.all()
  end

  @doc """
  Takes an account's posts out of a reader's home feed.

  Their own posts and everybody's boosts of them: somebody else's boost of the
  person just unfollowed is still that person's words in the timeline.

  Anything still reachable another way is left alone. A post that arrived
  because of a followed hashtag does not stop being about that hashtag when
  its author is unfollowed.
  """
  @spec unmerge_account(Account.t() | integer(), Account.t() | integer()) :: :ok
  def unmerge_account(%Account{id: reader_id}, author), do: unmerge_account(reader_id, author)

  def unmerge_account(reader_id, %Account{id: author_id}),
    do: unmerge_account(reader_id, author_id)

  def unmerge_account(reader_id, author_id) do
    doomed =
      from(s in Status, where: s.account_id == ^author_id, select: s.id) |> Repo.all()

    remove_unless_reachable(reader_id, doomed)
  end

  @doc """
  Takes everything about an account out: their posts, boosts of them, and posts
  that merely mention them.

  This is what a block or a mute means, and it is deliberately harsher than
  unfollowing. Unfollowing says "I do not subscribe to you", so a post of
  theirs that a friend boosted is still the friend's boost and stays. Blocking
  says "I do not want to see you", so it goes, and so does a post that only
  carries their handle.

  No reachability check either. There is no other reason that outranks a block.
  """
  @spec purge_account(Account.t() | integer(), Account.t() | integer()) :: :ok
  def purge_account(%Account{id: reader_id}, target), do: purge_account(reader_id, target)
  def purge_account(reader_id, %Account{id: target_id}), do: purge_account(reader_id, target_id)

  def purge_account(reader_id, target_id) do
    theirs =
      from(s in Status,
        left_join: b in Status,
        on: b.id == s.reblog_of_id,
        where: s.account_id == ^target_id or b.account_id == ^target_id,
        select: s.id
      )
      |> Repo.all()

    mentioning =
      from(m in Abuuba.Statuses.Mention, where: m.account_id == ^target_id, select: m.status_id)
      |> Repo.all()

    Feed.remove("home", reader_id, Enum.uniq(theirs ++ mentioning))
  end

  @doc """
  Puts a hashtag's recent posts into a reader's home feed.
  """
  @spec merge_tag(Account.t() | integer(), Tag.t()) :: :ok
  def merge_tag(%Account{id: reader_id}, tag), do: merge_tag(reader_id, tag)

  def merge_tag(reader_id, %Tag{id: tag_id}) do
    reader = Accounts.get_account(reader_id)

    Statuses.not_deleted()
    |> Statuses.visible_to(reader)
    |> join(:inner, [s], t in "statuses_tags", on: t.status_id == s.id)
    |> where([_s, t], t.tag_id == ^tag_id)
    # Public only. A followers-only post carrying a hashtag was still made to
    # followers, and a tag follow is not a follow.
    |> where([s], s.visibility in [:public, :unlisted])
    |> exclude_unwanted(reader)
    |> order_by([s], desc: s.id)
    |> limit(@backfill_limit)
    |> select([s], s.id)
    |> Repo.all()
    |> Enum.map(&%{feed_type: "home", feed_id: reader_id, status_id: &1})
    |> Feed.insert_many()
  end

  @doc """
  Takes a hashtag's posts out, leaving anything still reachable another way.
  """
  @spec unmerge_tag(Account.t() | integer(), Tag.t()) :: :ok
  def unmerge_tag(%Account{id: reader_id}, tag), do: unmerge_tag(reader_id, tag)

  def unmerge_tag(reader_id, %Tag{id: tag_id}) do
    doomed =
      from(t in "statuses_tags", where: t.tag_id == ^tag_id, select: t.status_id) |> Repo.all()

    remove_unless_reachable(reader_id, doomed)
  end

  @doc """
  Puts an account's recent posts into one list's feed.
  """
  @spec merge_list_member(AccountList.t(), Account.t() | integer()) :: :ok
  def merge_list_member(list, %Account{id: author_id}), do: merge_list_member(list, author_id)

  def merge_list_member(%AccountList{} = list, author_id) do
    owner = Accounts.get_account(list.account_id)

    Statuses.not_deleted()
    |> Statuses.visible_to(owner)
    |> where([s], s.account_id == ^author_id)
    |> exclude_unwanted(owner)
    |> apply_replies_policy(list)
    |> order_by([s], desc: s.id)
    |> limit(@backfill_limit)
    |> select([s], s.id)
    |> Repo.all()
    |> Enum.map(&%{feed_type: "list", feed_id: list.id, status_id: &1})
    |> Feed.insert_many()
  end

  # The same rule the fan-out applies to new posts, asked of the backlog: a
  # list that hides replies would otherwise be filled with them the moment
  # somebody was added to it.
  defp apply_replies_policy(query, %AccountList{replies_policy: "none"}) do
    where(query, [s], is_nil(s.in_reply_to_account_id))
  end

  defp apply_replies_policy(query, %AccountList{replies_policy: "followed"} = list) do
    where(
      query,
      [s],
      is_nil(s.in_reply_to_account_id) or
        exists(
          from(f in "follows",
            where:
              f.account_id == ^list.account_id and
                f.target_account_id == parent_as(:status).in_reply_to_account_id,
            select: 1
          )
        )
    )
  end

  defp apply_replies_policy(query, %AccountList{} = list) do
    where(
      query,
      [s],
      is_nil(s.in_reply_to_account_id) or
        exists(
          from(m in "list_accounts",
            where:
              m.list_id == ^list.id and
                m.account_id == parent_as(:status).in_reply_to_account_id,
            select: 1
          )
        )
    )
  end

  @doc """
  Takes an account's posts out of one list's feed.

  No reachability question here: a list is exactly its members, so a post
  belongs to it for one reason only.
  """
  @spec unmerge_list_member(AccountList.t(), Account.t() | integer()) :: :ok
  def unmerge_list_member(list, %Account{id: author_id}), do: unmerge_list_member(list, author_id)

  def unmerge_list_member(%AccountList{id: list_id}, author_id) do
    Feed.remove_author("list", list_id, author_id)
  end

  # The rule that makes unmerging safe: a post belongs in a feed for as many
  # reasons as the reader has, and removing one reason must not remove the
  # post if another still holds. Checked against what the reader follows now,
  # after the change that prompted this.
  defp remove_unless_reachable(reader_id, candidate_ids)
  defp remove_unless_reachable(_reader_id, []), do: :ok

  defp remove_unless_reachable(reader_id, candidate_ids) do
    still_wanted = reachable(reader_id, candidate_ids)

    Feed.remove("home", reader_id, Enum.reject(candidate_ids, &(&1 in still_wanted)))
  end

  defp reachable(reader_id, candidate_ids) do
    followed = from(f in Follow, where: f.account_id == ^reader_id, select: f.target_account_id)

    tags = from(t in "tag_follows", where: t.account_id == ^reader_id, select: t.tag_id)

    by_author =
      from(s in Status,
        where: s.id in ^candidate_ids,
        where: s.account_id in subquery(followed) or s.account_id == ^reader_id,
        select: s.id
      )

    by_tag =
      from(t in "statuses_tags",
        where: t.status_id in ^candidate_ids and t.tag_id in subquery(tags),
        select: t.status_id
      )

    MapSet.new(Repo.all(by_author) ++ Repo.all(by_tag))
  end

  # A boost the reader has asked not to see from this person. The backfill has
  # to ask the same question the fan-out asked, or following somebody with
  # boosts hidden imports the boosts anyway.
  defp exclude_unwanted_boosts(query, reader_id, author_id) do
    show_reblogs =
      Follow
      |> where([f], f.account_id == ^reader_id and f.target_account_id == ^author_id)
      |> select([f], f.show_reblogs)
      |> Repo.one()

    if show_reblogs == false, do: where(query, [s], is_nil(s.reblog_of_id)), else: query
  end

  @doc """
  Whether somebody's feed is still being put together.

  True for an empty feed that ought to have something in it: somebody coming
  back after long enough that theirs was trimmed away should be told it is
  being rebuilt rather than that there is nothing to read.
  """
  @spec regenerating?(Account.t() | integer()) :: boolean()
  def regenerating?(%Account{id: account_id}), do: regenerating?(account_id)

  def regenerating?(account_id) do
    home_size(account_id) == 0 and expects_something?(account_id)
  end

  @doc """
  How many posts somebody's home feed holds.
  """
  @spec home_size(Account.t() | integer()) :: non_neg_integer()
  def home_size(%Account{id: account_id}), do: home_size(account_id)
  def home_size(account_id), do: Feed.count("home", account_id)

  # Following somebody whose posts would actually land. Somebody who has put
  # everybody they follow into an exclusive list has an empty home feed on
  # purpose, and telling them it is being rebuilt would be a promise that never
  # comes true.
  defp expects_something?(account_id) do
    excluded = Lists.exclusive_member_ids(account_id)

    Follow
    |> where([f], f.account_id == ^account_id)
    |> where([f], f.target_account_id not in ^excluded)
    |> Repo.exists?()
  end

  ## Read markers

  @doc """
  Where somebody had read up to, for each timeline they asked about.
  """
  @spec markers(Account.t(), [String.t()]) :: %{String.t() => Marker.t()}
  def markers(%Account{id: account_id}, timelines) do
    wanted = Enum.filter(timelines, &(&1 in Marker.timelines()))

    Marker
    |> where([m], m.account_id == ^account_id and m.timeline in ^wanted)
    |> Repo.all()
    |> Map.new(&{&1.timeline, &1})
  end

  @doc """
  Moves a marker, refusing to move it backwards under another client.

  Two clients holding the same marker and both moving it is the ordinary case,
  not a rare one: somebody reads on a phone and then on a laptop. Last write
  wins would drag their place back to whatever the slower device believed, so
  a write against a stale version is refused and the client re-reads instead.

  A caller that passes no version is not participating in the check, which is
  what the reference implementation's clients do; theirs simply wins.
  """
  @spec put_marker(Account.t(), String.t(), integer(), integer() | nil) ::
          {:ok, Marker.t()} | {:error, :conflict | Ecto.Changeset.t()}
  def put_marker(%Account{id: account_id}, timeline, last_read_id, expected_version \\ nil) do
    existing = Repo.get_by(Marker, account_id: account_id, timeline: timeline)

    cond do
      stale?(existing, expected_version) ->
        {:error, :conflict}

      is_nil(existing) ->
        %Marker{}
        |> Marker.changeset(%{
          account_id: account_id,
          timeline: timeline,
          last_read_id: last_read_id
        })
        |> Repo.insert()

      true ->
        existing
        |> Marker.changeset(%{last_read_id: last_read_id, version: existing.version + 1})
        |> Repo.update()
    end
  end

  defp stale?(_existing, nil), do: false
  defp stale?(nil, _expected), do: false
  defp stale?(%Marker{version: version}, expected), do: version != expected
end

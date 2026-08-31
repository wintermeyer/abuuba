defmodule Abuuba.Statuses do
  @moduledoc """
  Posts, boosts and replies, and the things that hang off one.

  Two filters stand between the table and a reader, and a read path needs both.
  `not_deleted/0` drops soft-deleted rows, because deletion here leaves the row
  in place and querying `Status` directly is how a deleted post reappears in a
  timeline. `visible_to/2` drops what the reader is not entitled to see, which
  in a fediverse server is the mistake that matters: a direct message handed to
  a stranger cannot be taken back.

  The read functions here take a viewer rather than offering one as an option,
  so the unsafe call is not something you can write by accident. Where a caller
  genuinely needs to bypass either filter, the function says so in its name.
  """

  import Ecto.Query

  require Logger

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Outbox
  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.URIs
  alias Abuuba.Notifications
  alias Abuuba.Pagination
  alias Abuuba.PreviewCards
  alias Abuuba.PreviewCards.FetchWorker
  alias Abuuba.Relationships.Block
  alias Abuuba.Relationships.DomainBlock
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.Mute
  alias Abuuba.Repo
  alias Abuuba.Stats
  alias Abuuba.Statuses.Bookmark
  alias Abuuba.Statuses.Conversation
  alias Abuuba.Statuses.ConversationMute
  alias Abuuba.Statuses.Draft
  alias Abuuba.Statuses.Favourite
  alias Abuuba.Statuses.FeaturedTag
  alias Abuuba.Statuses.Formatter
  alias Abuuba.Statuses.IdempotencyKey
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Pin
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.PollVote
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.StatusEdit
  alias Abuuba.Statuses.Tag
  alias Abuuba.Timelines.FanOut
  alias Abuuba.Timelines.Feed
  alias Abuuba.Trends
  alias Abuuba.Webhooks
  alias Ecto.Multi

  # The reference implementation's cap, and the one this server advertises.
  @featured_tags_max 10

  # How far back "what you have been writing about" looks. Bounded because the
  # suggestion query runs on every settings page load and an account with ten
  # years of posts should not pay for all of them.
  @suggestion_window 200

  @doc """
  Every status that has not been soft-deleted.

  Named for exactly what it does, and no more. It says nothing about who may
  see a row, so on its own it will hand a caller somebody else's direct
  message. Compose it with `visible_to/2` for anything a person will read.
  """
  @spec not_deleted() :: Ecto.Query.t()
  def not_deleted, do: from(s in Status, as: :status, where: is_nil(s.deleted_at))

  @doc """
  Removes what the author will not show this reader.

  The author's own side of a block and nothing else: to somebody they have
  blocked, a blocker is a stranger, and public posts are exactly what
  strangers are otherwise handed. Asked of the post's author and of whoever a
  boost is carrying, because a block is about the person whose words these
  are, not about who passed them along.

  The narrow half of `excluding_hidden/2`, for the surfaces a reader reaches
  on purpose. Their own blocks and mutes are not here: those say what may be
  delivered, and "the one place you still see them is their own profile, if
  you go and look" is a promise the user guide makes about the other
  direction. `readable/2` is what composes this.

  Needs the `:status` binding that `not_deleted/0` carries.
  """
  @spec excluding_refused(Ecto.Query.t(), Account.t() | integer() | nil) :: Ecto.Query.t()
  def excluding_refused(query, nil), do: query

  def excluding_refused(query, %Account{id: viewer_id}), do: excluding_refused(query, viewer_id)

  def excluding_refused(query, viewer_id) do
    query
    |> where(
      [s],
      not exists(
        from b in Block,
          where:
            b.target_account_id == ^viewer_id and
              b.account_id == parent_as(:status).account_id
      )
    )
    |> where(
      [s],
      is_nil(s.reblog_of_id) or
        not exists(
          from o in Status,
            join: b in Block,
            on: b.target_account_id == ^viewer_id and b.account_id == o.account_id,
            where: o.id == parent_as(:status).reblog_of_id
        )
    )
  end

  # The three questions a reader's own rules come down to, each written once
  # and asked of whichever account an argument names: the author of a post, or
  # the author of what that post repeats.
  #
  # Macros rather than one set of author ids, which is what this looked like
  # for an afternoon. `a.id in subquery(...)` reads better and Postgres hoists
  # it into an anti-join over the whole `accounts` table: the public timeline
  # measured 1,230 ms and 2.7 million buffers against 6 ms and 1,363. Asked of
  # one id at a time, every one of these is an index probe.
  defmacrop blocked_either_way(viewer_id, subject) do
    quote do
      from(b in Block,
        where:
          (b.account_id == ^unquote(viewer_id) and b.target_account_id == unquote(subject)) or
            (b.target_account_id == ^unquote(viewer_id) and b.account_id == unquote(subject)),
        select: 1
      )
    end
  end

  defmacrop actively_muted(viewer_id, now, subject) do
    quote do
      from(m in Mute,
        where:
          m.account_id == ^unquote(viewer_id) and m.target_account_id == unquote(subject) and
            (is_nil(m.expires_at) or m.expires_at > ^unquote(now)),
        select: 1
      )
    end
  end

  # Blocking a domain is blocking everybody on it, and it was enforced only
  # where a post is written into a feed. The public and hashtag timelines and
  # search are live queries with no feed in front of them, so a reader who had
  # shut out a whole server still met it on all three.
  defmacrop on_a_blocked_server(viewer_id, subject) do
    quote do
      from(a in Account,
        join: d in DomainBlock,
        on: d.domain == a.domain and d.account_id == ^unquote(viewer_id),
        where: a.id == unquote(subject),
        select: 1
      )
    end
  end

  # None of the three, of whichever account `subject` names.
  defmacrop wanted_author(viewer_id, now, subject) do
    quote do
      not exists(blocked_either_way(unquote(viewer_id), unquote(subject))) and
        not exists(actively_muted(unquote(viewer_id), unquote(now), unquote(subject))) and
        not exists(on_a_blocked_server(unquote(viewer_id), unquote(subject)))
    end
  end

  @doc """
  Removes what a reader's blocks and mutes hide, in both directions.

  Separate from `visible_to/2` because the two answer different questions:
  that one asks whether a post was addressed widely enough to reach this
  reader, this one asks whether the two people are on speaking terms. A
  timeline needs both and used to be the only thing that had them -- search
  asked the first and not the second, so an account that had blocked somebody
  could still be read by them through the search box, which is precisely the
  reading a block exists to stop. To a blocked reader the blocker is a
  stranger, and public posts are what strangers are otherwise handed.

  Needs the `:status` binding that `not_deleted/0` carries.
  """
  @spec excluding_hidden(Ecto.Query.t(), Account.t() | integer() | nil) :: Ecto.Query.t()
  def excluding_hidden(query, nil), do: query

  def excluding_hidden(query, %Account{id: viewer_id}), do: excluding_hidden(query, viewer_id)

  def excluding_hidden(query, viewer_id) do
    now = DateTime.utc_now()

    query
    |> where([s], wanted_author(viewer_id, now, parent_as(:status).account_id))
    |> where(
      [s],
      is_nil(s.reblog_of_id) or
        exists(
          from(o in Status,
            as: :carried,
            where: o.id == parent_as(:status).reblog_of_id,
            where: wanted_author(viewer_id, now, parent_as(:carried).account_id),
            select: 1
          )
        )
    )
  end

  @doc """
  Removes the threads this reader has put down.

  Apart from `excluding_hidden/2` because it answers a different question: not
  whether the two are on speaking terms, but whether this conversation is one
  the reader has stopped following. A timeline applies it and a search does
  not, which is why it is a filter of its own rather than folded into that
  one.

  Needs the `:status` binding that `not_deleted/0` carries.
  """
  @spec excluding_muted_threads(Ecto.Query.t(), Account.t() | integer() | nil) :: Ecto.Query.t()
  def excluding_muted_threads(query, nil), do: query

  def excluding_muted_threads(query, %Account{id: viewer_id}),
    do: excluding_muted_threads(query, viewer_id)

  def excluding_muted_threads(query, viewer_id) do
    where(
      query,
      [s],
      is_nil(s.conversation_id) or
        not exists(
          from c in ConversationMute,
            where:
              c.account_id == ^viewer_id and
                c.conversation_id == parent_as(:status).conversation_id
        )
    )
  end

  @doc """
  Whether one post is something this reader has said they do not want.

  The row-at-a-time twin of `excluding_hidden/2`, and it exists because a live
  event never passes through a timeline query. The streaming API and the
  timeline a browser is watching each receive a post directly, so each had
  grown a partial copy of these rules -- and each was missing a different one.
  Asked here so there is one answer rather than three.
  """
  @spec hidden_for?(Status.t(), Account.t() | integer() | nil) :: boolean()
  def hidden_for?(_status, nil), do: false

  def hidden_for?(%Status{} = status, viewer) do
    # One query rather than six. This runs for every post that arrives, once
    # per socket watching -- a post reaching a thousand readers asked six
    # thousand questions to answer one. The rules are unchanged; they are asked
    # together instead of in turn.
    viewer_id = viewer_id(viewer)
    now = DateTime.utc_now()

    Account
    |> from(as: :author)
    |> where([a], a.id in subquery(author_ids(status)))
    |> where([a], not wanted_author(viewer_id, now, parent_as(:author).id))
    |> Repo.exists?() or thread_muted?(viewer, status)
  end

  # The post's own author, and the author of what it repeats: a block has to
  # survive a third party passing the words along.
  defp author_ids(%Status{} = status) do
    carried = status.reblog_of_id || status.id

    from(s in Status, where: s.id == ^status.id or s.id == ^carried, select: s.account_id)
  end

  defp viewer_id(%Account{id: id}), do: id
  defp viewer_id(id), do: id

  # The same three questions again, about the author of what a boost carries.
  #
  # A block is about the person, not about who passed their post along, and
  # every check above matches the row's own `account_id` -- which for a boost
  # is the booster. So blocking somebody still let their words through inside
  # anybody else's boost, which is the one hole a person notices at once.
  #
  # Guarded on `reblog_of_id` being there rather than folded into the clauses
  # above: an ordinary post is the overwhelming majority of any page, and this
  # way it pays a null check instead of a second probe through `statuses`.
  @doc """
  Removes boosts of somebody the reader will not deal with, and nothing else.

  For a profile, where the whole page is one account on purpose. Looking at
  somebody is deliberate in a way a timeline is not, so what they wrote
  themselves is shown even to a reader who has blocked them -- but what they
  passed along is the blocked account's own words, which is the thing a block
  is about. The reference implementation draws the line in the same place.
  """
  @spec excluding_boosts_of_hidden(Ecto.Query.t(), Account.t() | integer() | nil) ::
          Ecto.Query.t()
  def excluding_boosts_of_hidden(query, nil), do: query

  def excluding_boosts_of_hidden(query, %Account{id: viewer_id}),
    do: excluding_boosts_of_hidden(query, viewer_id)

  def excluding_boosts_of_hidden(query, viewer_id),
    do: excluding_hidden_boosts(query, viewer_id, DateTime.utc_now())

  defp excluding_hidden_boosts(query, viewer_id, now) do
    query
    |> excluding_boosts_of_blocked(viewer_id)
    |> excluding_boosts_of_muted(viewer_id, now)
    |> excluding_boosts_from_blocked_domains(viewer_id)
  end

  defp excluding_boosts_of_blocked(query, viewer_id) do
    where(
      query,
      [s],
      is_nil(s.reblog_of_id) or
        not exists(
          from o in Status,
            join: b in Block,
            on:
              (b.account_id == ^viewer_id and b.target_account_id == o.account_id) or
                (b.target_account_id == ^viewer_id and b.account_id == o.account_id),
            where: o.id == parent_as(:status).reblog_of_id
        )
    )
  end

  defp excluding_boosts_of_muted(query, viewer_id, now) do
    where(
      query,
      [s],
      is_nil(s.reblog_of_id) or
        not exists(
          from o in Status,
            join: m in Mute,
            on:
              m.account_id == ^viewer_id and m.target_account_id == o.account_id and
                (is_nil(m.expires_at) or m.expires_at > ^now),
            where: o.id == parent_as(:status).reblog_of_id
        )
    )
  end

  defp excluding_boosts_from_blocked_domains(query, viewer_id) do
    where(
      query,
      [s],
      is_nil(s.reblog_of_id) or
        not exists(
          from o in Status,
            join: a in Account,
            on: a.id == o.account_id,
            join: d in DomainBlock,
            on: d.domain == a.domain and d.account_id == ^viewer_id,
            where: o.id == parent_as(:status).reblog_of_id
        )
    )
  end

  @doc """
  Narrows a query to what `viewer` is allowed to see. Pass `nil` for a logged
  out reader.

  Public and unlisted statuses are readable by anyone; the difference between
  them is whether they appear in discovery surfaces, not who may fetch them.
  A followers-only status is readable by the author's followers. Everything
  else is readable by its author and by the accounts it addresses, and being
  addressed grants access whatever the visibility, which is what makes a direct
  message reach the person it names.
  """
  @spec visible_to(Ecto.Query.t(), Account.t() | integer() | nil) :: Ecto.Query.t()
  def visible_to(query, nil) do
    from s in query, where: s.visibility in [:public, :unlisted]
  end

  def visible_to(query, %Account{id: id}), do: visible_to(query, id)

  def visible_to(query, viewer_id) do
    addressed = from m in Mention, where: m.account_id == ^viewer_id, select: m.status_id

    followed =
      from f in Follow, where: f.account_id == ^viewer_id, select: f.target_account_id

    from s in query,
      where:
        s.visibility in [:public, :unlisted] or
          s.account_id == ^viewer_id or
          s.id in subquery(addressed) or
          (s.visibility == :private and s.account_id in subquery(followed))
  end

  # A profile answers nothing at all to somebody its owner has blocked, which
  # the visibility rules alone do not cover: to them a blocked reader is a
  # stranger, and public posts are exactly what strangers get. Asked here
  # rather than in each controller so every surface gets the same answer --
  # the web profile and the REST API both come through these two functions.
  defp blocked_reader?(_account_id, nil), do: false

  defp blocked_reader?(account_id, %Account{id: viewer_id}),
    do: blocked_reader?(account_id, viewer_id)

  defp blocked_reader?(account_id, viewer_id) when account_id == viewer_id, do: false

  defp blocked_reader?(account_id, viewer_id) do
    Block
    |> where([b], b.account_id == ^account_id and b.target_account_id == ^viewer_id)
    |> Repo.exists?()
  end

  @doc """
  Every status including the deleted ones. For moderation and for federation
  bookkeeping, which both need to see what was removed.
  """
  @spec with_deleted() :: Ecto.Query.t()
  def with_deleted, do: from(s in Status)

  ## Writing

  @doc """
  Creates a status with whatever it carries, in one transaction.

  Media and a poll go in with the row or not at all. Attaching them afterwards
  meant two things went wrong at once: a poll the changeset refused left a
  published post behind that its author had been told was refused, and every
  subscriber — the streaming API, the live timeline, the outbox — was handed
  the status as it looked before its pictures were on it, so a photo post
  arrived with no photographs and never reached the media streams.

  `announce/1` runs after the commit for the same reason it always has: a
  broadcast is the one thing here that does not come back when a transaction
  rolls back.
  """
  @spec create_status(map(), keyword()) ::
          {:ok, Status.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_status(attrs, opts \\ []) do
    media_ids = Keyword.get(opts, :media_ids, [])
    poll = Keyword.get(opts, :poll)

    # The row and its counters commit together. Separately, a concurrent
    # un-action could see the row before its `+1` landed, decrement past zero
    # and trip the counters' CHECK constraint.
    Multi.new()
    |> Multi.run(:parent, fn _repo, _changes -> {:ok, parent_of(attrs)} end)
    |> Multi.insert(:status, fn %{parent: parent} ->
      Status.changeset(%Status{}, derived(attrs, parent))
    end)
    |> Multi.run(:counters, fn _repo, %{status: status} ->
      {:ok, count_status(status, 1)}
    end)
    |> Multi.run(:media, fn _repo, %{status: status} ->
      attach_media(status, media_ids)
    end)
    |> Multi.run(:poll, fn _repo, %{media: status} ->
      insert_poll(status, poll)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{media: status}} -> {:ok, announce(status)}
      {:error, :parent, reason, _changes} -> {:error, reason}
      {:error, :status, changeset, _changes} -> {:error, changeset}
      {:error, :media, reason, _changes} -> {:error, reason}
      {:error, :poll, reason, _changes} -> {:error, reason}
    end
  end

  # The two things a post inherits from the one it answers, worked out here
  # rather than at each front door.
  #
  # Both used to be set only by the compose form. A conversation was therefore
  # missing from every thread this server started, so none of them could be
  # muted (#221); and `in_reply_to_account_id` was missing from every reply
  # made through the API, which clients read to draw "in reply to @somebody"
  # and which fan-out reads to decide who a reply is shown to — so the same
  # reply reached a different set of people depending on which door it came
  # through (#222).
  #
  # A caller that names either wins. The federation path knows the conversation
  # from the remote thread's URI, and the importer knows the author of a parent
  # that may not exist here at all; both are facts rather than defaults.
  defp parent_of(attrs) do
    case field(attrs, :in_reply_to_id) do
      nil ->
        nil

      id ->
        Status
        |> where([s], s.id == ^id)
        |> select([s], map(s, [:account_id, :conversation_id]))
        |> Repo.one()
    end
  end

  defp derived(attrs, parent) do
    attrs
    |> put_new_field(:conversation_id, conversation_for(attrs, parent))
    |> put_new_field(:in_reply_to_account_id, parent && parent.account_id)
  end

  defp conversation_for(attrs, parent) do
    field(attrs, :conversation_id) || (parent && parent.conversation_id) || new_conversation()
  end

  defp new_conversation do
    {:ok, conversation} = upsert_conversation(nil)

    conversation.id
  end

  # Attrs reach here as a map with either kind of key, depending on which front
  # door built them.
  defp field(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  # Ecto refuses a params map that mixes string and atom keys, so anything added
  # here has to match whatever the caller was already using.
  #
  # "Not already filled in" means nil as well as absent. A caller that builds
  # its attrs as a fixed map — the federation path does — writes the key with
  # nothing in it, and `Map.put_new` would leave it that way: a post arriving
  # with no conversation named would keep no conversation at all, which is the
  # state this derivation exists to prevent.
  defp put_new_field(attrs, _key, nil), do: attrs

  defp put_new_field(attrs, key, value) do
    if field(attrs, key) do
      attrs
    else
      Map.put(attrs, matching_key(attrs, key), value)
    end
  end

  defp matching_key(attrs, key) do
    if Enum.any?(Map.keys(attrs), &is_binary/1), do: to_string(key), else: key
  end

  defp attach_media(status, []), do: {:ok, status}

  defp attach_media(status, ids), do: Abuuba.Media.attach_within(status, ids)

  defp insert_poll(_status, nil), do: {:ok, nil}

  defp insert_poll(status, attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"status_id" => status.id, "account_id" => status.account_id})

    %Poll{} |> Poll.changeset(attrs) |> Repo.insert()
  end

  # Everything a freshly published post owes the world beyond its row. Done
  # here rather than at each caller: a post made by the API, by the composer,
  # by the scheduled-post worker or by another server is the same post, and
  # one of those callers would eventually forget.
  defp announce(status) do
    link_text(status)

    # Written into every feed it belongs in, and counted towards what is
    # trending, both decided once when the post is made.
    FanOut.deliver(status)
    Abuuba.Conversations.deliver(status)
    Trends.record_status(status)

    # Queued rather than done here: unfurling means talking to a server that
    # may be slow or down, and posting would be as slow as the slowest site
    # anybody links to.
    FetchWorker.enqueue(status)

    # Announced as soon as it exists, so that a timeline somebody is watching
    # shows their own post the moment they make it rather than on the next
    # poll.
    Abuuba.Streaming.publish_status(status)

    # And out to the rest of the network. Last, because it is the only step
    # that leaves this server: everything above has to be true before anybody
    # elsewhere can come back and ask about the post.
    Outbox.status_created(status)

    # And to whoever the admin has pointed a webhook at. Local posts only: a
    # moderation tool asked about this server, and every post arriving from
    # elsewhere would drown what it asked for.
    if is_nil(status.uri) or status.local, do: webhook("status.created", status)

    status
  end

  # What a moderation tool is watching for, and nothing more: the post's
  # address and its author, not its text. A receiver that wants the words can
  # fetch them, and a webhook body is a copy of somebody's writing sitting in
  # somebody else's logs.
  defp webhook(event, %Status{} = status) do
    Webhooks.announce(event, %{
      "id" => to_string(status.id),
      "account_id" => to_string(status.account_id),
      "visibility" => to_string(status.visibility),
      "url" => Serializer.status_uri(status)
    })
  end

  @doc """
  Writes a post that was made somewhere else and is being read back in.

  A second door, and a deliberate one. `create_status/1` does everything a new
  post needs: it goes into followers' timelines, it is counted towards what is
  trending, it is announced to anybody watching a live timeline, and its links
  are unfurled. An imported post is written now and was published years ago,
  and every one of those would treat the first date as the second.

  Nobody's followers asked to be shown a decade of somebody else's history in
  one go, nothing from 2015 should be trending this afternoon, and unfurling
  every link in an archive means a burst of requests to a few thousand sites.
  So this inserts the row and links its text, and stops there.
  """
  @spec import_status(map()) :: {:ok, Status.t()} | {:error, Ecto.Changeset.t()}
  def import_status(attrs) do
    # The counters move like any other write, but `last_status_at` stays: an
    # archive is old news, and stamping it would put a decade-old post
    # forward as the latest thing this person said.
    Multi.new()
    |> Multi.insert(:status, Status.import_changeset(%Status{}, attrs))
    |> Multi.run(:counters, fn _repo, %{status: status} ->
      {:ok, count_status(status, 1, last_status: false)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{status: status}} ->
        link_text(status)

        {:ok, status}

      {:error, :status, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  The HTML a reader sees for a status.

  Local posts are plain text until here: the linking happens on the way out,
  so an edit to a handle or a tag is reflected the next time the post is read
  rather than being frozen into it at the moment it was written.

  Another server's post is already HTML and was cleaned when it arrived, so it
  passes through. Everything that renders a post goes through this function,
  which is what keeps the composer's preview, the API and what federates from
  being three different answers.

  Pass `:accounts` and `:emojis` when rendering a page, so that the mentions
  and emoji already loaded for it are reused rather than looked up per post.
  """
  @spec content_html(Status.t(), keyword()) :: String.t()
  def content_html(status, opts \\ [])
  def content_html(%Status{local: true, text: text}, opts), do: Formatter.to_html(text, opts)
  def content_html(%Status{text: text}, _opts), do: text || ""

  @doc """
  Records who a status addresses and what it is filed under, from its text.

  Run on every write rather than at the composer, because the same text arrives
  from the API, from a scheduled post and from an edit, and a mention that only
  the composer records is one that never reaches anybody.

  Failing to resolve a handle is not an error. Somebody mistypes a name, or
  names an account on a server this one has never spoken to, and refusing the
  post over it would be worse than posting it with one word unlinked.
  """
  @spec link_text(Status.t()) :: Status.t()
  def link_text(%Status{local: true} = status) do
    relink_mentions(status)
    relink_tags(status)

    status
  end

  # Another server's mentions and tags arrive in the document as data, and its
  # text is rendered HTML. Reading handles and tags back out of that markup
  # finds the anchors rather than the people.
  def link_text(%Status{} = status), do: status

  defp relink_mentions(%Status{id: id, text: text}) do
    wanted =
      text
      |> Formatter.mentions()
      |> Enum.flat_map(&List.wrap(Accounts.lookup(&1)))
      |> Enum.uniq_by(& &1.id)

    wanted_ids = Enum.map(wanted, & &1.id)

    # Quieted rather than deleted. The row is what grants access to a post
    # addressed narrowly, so deleting it takes away something the reader had
    # already been given -- a direct message could disappear from the inbox of
    # the person it was sent to, after they had read it and perhaps answered.
    # Silent keeps the original concern answered: no further notification, and
    # nothing new delivered to somebody the author decided not to talk to.
    from(m in Mention,
      where: m.status_id == ^id and m.account_id not in ^wanted_ids and not m.silent
    )
    |> Repo.update_all(set: [silent: true, updated_at: DateTime.utc_now()])

    # Only the ones the text still names. A quieted row must not stop the
    # handle coming back from being heard about again, and it must not be
    # inserted twice either, so the ones named now are unsilenced in place.
    from(m in Mention,
      where: m.status_id == ^id and m.account_id in ^wanted_ids and m.silent
    )
    |> Repo.update_all(set: [silent: false, updated_at: DateTime.utc_now()])

    known = from(m in Mention, where: m.status_id == ^id, select: m.account_id) |> Repo.all()

    wanted
    |> Enum.reject(&(&1.id in known))
    |> Enum.each(fn account ->
      # A concurrent write may have recorded the same mention between the read
      # above and this insert, which the unique index turns into a refusal. It
      # means somebody is already addressed, so there is nothing to repair and
      # nothing to announce.
      mention(id, account)
    end)
  end

  defp relink_tags(%Status{id: id, text: text}) do
    wanted =
      text
      |> Formatter.hashtags()
      |> Enum.flat_map(fn name ->
        case upsert_tag(name) do
          {:ok, tag} -> [tag.id]
          {:error, _} -> []
        end
      end)

    from(t in "statuses_tags", where: t.status_id == ^id and t.tag_id not in ^wanted)
    |> Repo.delete_all()

    Enum.each(wanted, &tag_status(id, &1))
  end

  @doc """
  Boosts a status.

  The boost is a status of its own with no text, pointing at the original. A
  boost of a boost points at the original rather than at the intermediate one,
  which is what keeps a chain of boosts from nesting without limit and matches
  what every client renders.
  """
  @spec boost(Account.t() | integer(), Status.t()) ::
          {:ok, Status.t()} | {:error, Ecto.Changeset.t()}
  def boost(%Account{id: account_id}, status), do: boost(account_id, status)

  def boost(account_id, %Status{} = status) do
    boosted_id = status.reblog_of_id || status.id

    create_status(%{
      account_id: account_id,
      reblog_of_id: boosted_id,
      visibility: status.visibility,
      conversation_id: status.conversation_id,
      # From whoever is doing the boosting. The column defaults to true, so an
      # inbound `Announce` from another server used to record a boost of theirs
      # as one of ours: it then appeared on the local timeline and counted as
      # local in every query that asks where a post came from.
      local: local_account?(account_id)
    })
    |> tap(fn
      # On the boosted post rather than on the boost, so the notification names
      # what the author wrote. A boost of a boost credits the original, which
      # is the same post `boosted_id` already points at.
      {:ok, boost} ->
        notify_about(boosted_id, account_id, "reblog",
          status_id: boost.id,
          group_key: "reblog-#{boosted_id}"
        )

      _ ->
        :ok
    end)
  end

  # Whoever wrote the post, about something somebody else did to it. Silent
  # when the post has gone, and `notify/4` itself refuses to tell somebody
  # about their own action.
  # Whoever put their name to this post by boosting it. They showed it to their
  # own followers, so words changing underneath them is their business as much
  # as the author's.
  defp notify_boosters(%Status{} = status) do
    Status
    |> where([s], s.reblog_of_id == ^status.id and is_nil(s.deleted_at))
    |> select([s], s.account_id)
    |> Repo.all()
    |> Enum.each(
      &Notifications.notify(&1, status.account_id, "update",
        status_id: status.id,
        group_key: "update-#{status.id}"
      )
    )

    :ok
  end

  # The other half of `notify_about/4`: the author was told, and the thing they
  # were told about has been taken back.
  defp notify_forget(status_id, from_account_id, type) do
    case Repo.get(Status, status_id) do
      nil ->
        :ok

      status ->
        Notifications.forget(status.account_id, from_account_id, type, status_id: status_id)
    end

    :ok
  end

  defp notify_about(status_id, from_account_id, type, opts \\ []) do
    opts = Keyword.put_new(opts, :status_id, status_id)

    case Repo.get(Status, status_id) do
      nil -> :ok
      status -> Notifications.notify(status.account_id, from_account_id, type, opts)
    end

    :ok
  end

  defp local_account?(account_id) do
    Account |> where([a], a.id == ^account_id) |> select([a], is_nil(a.domain)) |> Repo.one() ||
      false
  end

  @doc """
  Soft-deletes a status.
  """
  @spec delete_status(Status.t()) :: {:ok, Status.t()}
  def delete_status(%Status{} = status) do
    now = DateTime.utc_now()

    # The guard comes first: deleting twice — a retried request, a moderator
    # and the author racing — must move the counters once, and the feed sweep
    # and the announcement are wasted work for a row that was already gone.
    # The counters ride the same transaction as the flip, so a concurrent
    # reader never sees one without the other.
    {:ok, undeleted} =
      Repo.transaction(fn ->
        {undeleted, _} =
          Status
          |> where([s], s.id == ^status.id and is_nil(s.deleted_at))
          |> Repo.update_all(set: [deleted_at: now, updated_at: now])

        if undeleted == 1, do: count_status(status, -1)

        undeleted
      end)

    if undeleted == 1 do
      Abuuba.Streaming.publish_delete(status)
      Feed.remove_status(status.id)

      # A pin of a post that no longer exists is a permanently occupied place
      # on the board: the profile does not show it and unpinning it answers
      # 404, so it has to go with the post.
      Pin |> where([p], p.status_id == ^status.id) |> Repo.delete_all()

      # And out of the inboxes that named it, for the same reason: a line
      # about a post nobody can open, with a readable one sitting behind it.
      Abuuba.Conversations.forget(status)

      # And the notifications about it. `notifications.status_id` would do
      # this through its foreign key if the delete were a real one; it is a
      # soft delete, so the row survives and the key never fires. This is also
      # what takes a boost's notification back when somebody unboosts, since
      # unboosting deletes the boost.
      Notifications.forget_status(status.id)

      # Inside the guard, so a retried delete does not send a second one.
      Outbox.status_deleted(status)
    end

    {:ok, %{status | deleted_at: status.deleted_at || now}}
  end

  # The counters one status moves, forwards on the way in and backwards on
  # the way out — the two must mirror each other exactly, or a delete takes
  # back what was never given and trips the counters' CHECK constraint.
  #
  # What the reference implementation counts, this counts: a direct message
  # moves no counter at all — a stranger reading a profile must not learn how
  # often somebody writes in private — and a reply counts on its parent only
  # when strangers could read it. `last_status_at` is the post's own time, so
  # a backfilled old post does not present itself as today's news.
  defp count_status(status, by, opts \\ [])

  defp count_status(%Status{visibility: :direct}, _by, _opts), do: :ok

  defp count_status(%Status{} = status, by, opts) do
    author_changes =
      if by > 0 and Keyword.get(opts, :last_status, true) do
        [statuses_count: by, last_status_at: status.inserted_at]
      else
        [statuses_count: by]
      end

    Stats.bump_account(status.account_id, author_changes)

    if status.in_reply_to_id && status.visibility in [:public, :unlisted] do
      Stats.bump_status(status.in_reply_to_id, replies_count: by)
    end

    if status.reblog_of_id do
      Stats.bump_status(status.reblog_of_id, reblogs_count: by)
    end

    :ok
  end

  @doc """
  Sets who may quote a post.

  Its own function rather than part of `edit_status/2`: changing the policy is
  not an edit of what the post says, so it snapshots no revision and does not
  stamp `edited_at`. Peers are told, because the policy travels in the object.
  """
  @spec set_quote_policy(Status.t(), String.t() | atom() | nil) ::
          {:ok, Status.t()} | {:error, Ecto.Changeset.t()}
  def set_quote_policy(%Status{} = status, policy) do
    status
    |> Status.changeset(%{"quote_policy" => policy})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> Outbox.status_edited(updated)
      _ -> :ok
    end)
  end

  @doc """
  Edits a status, snapshotting what it said first.

  The snapshot and the edit are one transaction. Written as two steps, a
  failure in between loses the previous revision, which is the one thing the
  history exists to keep.
  """
  @spec edit_status(Status.t(), map()) :: {:ok, Status.t()} | {:error, Ecto.Changeset.t()}
  def edit_status(%Status{} = status, attrs) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.insert(:snapshot, StatusEdit.from_status(status))
    # Normalised to string keys before the timestamp goes in. `cast/3` refuses
    # a map that mixes the two, so an API request arriving with string keys
    # would otherwise raise here rather than validate.
    |> Multi.update(:status, Status.changeset(status, stamp_edit(attrs, now)))
    |> Repo.transaction()
    |> case do
      {:ok, %{status: status}} ->
        # Whoever is watching sees the new words rather than the old ones for
        # as long as the cached payload lives.
        Abuuba.Streaming.publish_update(status)

        status = link_text(status)

        # Everything `create_status/2` does after the row exists has to be
        # asked again when the row changes. These two were not: an edited post
        # kept the card of a link it no longer carried, and a handle added to a
        # direct message wrote a mention and a notification without an inbox
        # row to read them in.
        PreviewCards.relink(status)
        FetchWorker.enqueue(status)
        Abuuba.Conversations.deliver(status)
        notify_boosters(status)

        # After the relink, so a handle added by the edit is in the audience
        # the delivery is worked out from.
        Outbox.status_edited(status)
        webhook("status.updated", status)

        {:ok, status}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Every revision of a status, oldest first.
  """
  @spec edit_history(Status.t() | integer()) :: [StatusEdit.t()]
  def edit_history(%Status{id: id}), do: edit_history(id)

  def edit_history(status_id) do
    StatusEdit |> where([e], e.status_id == ^status_id) |> order_by([e], asc: e.id) |> Repo.all()
  end

  ## Reading

  @doc """
  Statuses by id, in the order the ids were given.

  Order is the caller's, because a ranking's whole content is its order and a
  database has no opinion about it.
  """
  @spec get_statuses([integer() | String.t()]) :: [Status.t()]
  def get_statuses(ids), do: by_ids(ids, not_deleted())

  @doc """
  Statuses by id, in the order the ids were given, narrowed to what `viewer`
  may see. Pass `nil` for a logged out reader.

  Audience only, the batch twin of `get_status/2`. `get_statuses/1` without the
  narrowing is for callers whose ids are public by construction. What a reader
  is about to be shown goes through `readable_many/2`, which asks their blocks
  and mutes as well; this one is left for the notification and conversation
  envelopes, where a row referring to a post the reader has since hidden is a
  question of its own.
  """
  @spec get_visible_statuses([integer() | String.t()], Account.t() | nil) :: [Status.t()]
  def get_visible_statuses(ids, viewer), do: by_ids(ids, visible_to(not_deleted(), viewer))

  @doc """
  Statuses by id, in the order the ids were given, narrowed by `scope`.

  The shared body behind the three reads above, public because a caller with
  a scope of its own needs it too: `Abuuba.Timelines` reads a ranking's ids
  through the filters a timeline applies, which is none of the three. Ids may
  be strings, and anything that is not a number is simply not a post.
  """
  @spec by_ids([integer() | String.t()], Ecto.Query.t()) :: [Status.t()]
  def by_ids([], _scope), do: []

  def by_ids(ids, scope) do
    numbers = Enum.flat_map(ids, &List.wrap(to_id(&1)))

    found =
      scope
      |> where([s], s.id in ^numbers)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(numbers, &List.wrap(Map.get(found, &1)))
  end

  @doc """
  Tags by name, in the order the names were given.
  """
  @spec get_tags([String.t()]) :: [Tag.t()]
  def get_tags([]), do: []

  def get_tags(names) do
    names = Enum.map(names, &String.downcase/1)

    found = Tag |> where([t], t.name in ^names) |> Repo.all() |> Map.new(&{&1.name, &1})

    Enum.flat_map(names, &List.wrap(Map.get(found, &1)))
  end

  defp to_id(value) when is_integer(value), do: value

  defp to_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp to_id(_value), do: nil

  @doc """
  Fetches a status `viewer` was addressed widely enough to reach, or `nil`.

  Audience only. It answers whether the post was public, or private to people
  including this reader — not whether the two are on speaking terms. For
  anything a person is about to be shown, use `readable/2`, which asks both.

  This one is for a caller acting on a post the reader named from a list that
  was not filtered for them. `bookmarks/2` and `favourites/2` are that list:
  they answer what somebody saved, whatever they have done about the author
  since, and the action bar drawn over them has to reach every row it draws.

  A viewer is required rather than optional: the version of this function that
  took an id alone was one autocomplete away from serving direct messages.
  """
  @spec get_status(integer() | nil, Account.t() | integer() | nil) :: Status.t() | nil
  # A URL carrying something that is not an id asks for a post that does not
  # exist, which is a 404 rather than a 500.
  def get_status(nil, _viewer), do: nil

  def get_status(id, viewer) do
    not_deleted() |> visible_to(viewer) |> Repo.get(id)
  end

  @doc """
  Fetches a status to show to `viewer`, or `nil`. Pass `nil` for a logged out
  reader, which restricts the result to public and unlisted statuses.

  The one door for handing a reader a post they asked for by id. Two questions
  in a single query: `visible_to/2` for the audience, and `excluding_refused/2`
  for the author's own block — of the reader, and of the reader by whoever a
  boost is carrying.

  Only `visible_to/2` used to be asked here, so `GET /statuses/:id`, the batch,
  a poll, an annual report and the post pages all handed a reader posts from
  an account that had blocked them. The rule was written down once in the
  timeline queries and enforced only there. The embed and the oEmbed have no
  reader to ask about and come through for the sake of one door, not because
  they leaked.

  The reader's *own* blocks and mutes are deliberately not part of it. Those
  decide what is delivered, not what may be opened: "the one place you still
  see them is their own profile, if you go and look" is a promise the user
  guide makes, and a profile that lists a post whose link answers nothing
  breaks it. `readable?/2` is the twin that asks the reader's side, for the
  paths where a post arrives unasked.
  """
  @spec readable(integer() | nil, Account.t() | integer() | nil) :: Status.t() | nil
  def readable(nil, _viewer), do: nil
  def readable(id, viewer), do: not_deleted() |> reading_scope(viewer) |> Repo.get(id)

  @doc """
  The same read for several ids at once, in the order they were given.

  One query rather than one per id, and one answer rather than a caller's
  choice of filters.
  """
  @spec readable_many([integer() | String.t()], Account.t() | integer() | nil) :: [Status.t()]
  def readable_many([], _viewer), do: []
  def readable_many(ids, viewer), do: by_ids(ids, reading_scope(not_deleted(), viewer))

  @doc """
  Fetches a status `viewer` may take one of their own marks off, or `nil`.

  `readable/2`, or failing that a post they have already favourited,
  bookmarked, boosted or muted the thread of. `bookmarks/2` and `favourites/2`
  answer what somebody saved whatever they have done about the author since,
  so the button drawn over a saved row has to reach it — and having a mark on
  a post is proof they could read it when they made it.

  Only for taking a mark back. Putting one on is being shown the post, so
  `favourite`, `bookmark`, `reblog`, `mute` and `pin` go through `readable/2`
  like any other read: the reference implementation draws the line in the same
  place, refusing all five to a reader the author has blocked.
  """
  @spec actionable(integer() | nil, Account.t() | integer() | nil) :: Status.t() | nil
  def actionable(id, viewer), do: readable(id, viewer) || own_mark(id, viewer)

  defp own_mark(id, viewer) do
    with %Status{} = status <- get_status(id, viewer),
         true <- marked_by?(status, viewer_id(viewer)) do
      status
    else
      _unmarked -> nil
    end
  end

  defp marked_by?(_status, nil), do: false

  defp marked_by?(%Status{id: status_id} = status, viewer_id) do
    favourited?(viewer_id, status_id) or bookmarked?(viewer_id, status_id) or
      boosted?(viewer_id, status_id) or thread_muted?(viewer_id, status)
  end

  @doc """
  Whether a post that arrived unasked may be handed to `viewer`.

  Everything `readable/2` asks and the reader's own side as well — their
  blocks, their mutes, the servers they have shut out and the threads they
  have put down. That is the difference between the two: opening a link is
  deliberate, and a timeline is where all four are meant to take effect.

  The streaming transports ask this once per post per open socket, and a
  boolean is all they want, so it is one `EXISTS` rather than a row fetch
  followed by `hidden_for?/2` — three round trips for one answer, on the
  hottest path in the server.
  """
  @spec readable?(Status.t(), Account.t() | integer() | nil) :: boolean()
  def readable?(%Status{} = status, viewer) do
    not_deleted()
    |> delivery_scope(viewer)
    |> where([s], s.id == ^status.id)
    |> Repo.exists?()
  end

  # What a reader may open, and what may be pushed at them. Two scopes because
  # they are two questions, and the second is the first plus the reader's own
  # side of it.
  defp reading_scope(query, viewer), do: query |> visible_to(viewer) |> excluding_refused(viewer)

  defp delivery_scope(query, viewer) do
    query
    |> visible_to(viewer)
    |> excluding_hidden(viewer)
    |> excluding_muted_threads(viewer)
  end

  defp stamp_edit(attrs, now) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("edited_at", now)
  end

  @doc """
  Fetches a status regardless of who may read it. For moderation and for
  federation bookkeeping, never for rendering to a reader.
  """
  @spec get_status_unchecked(integer() | nil) :: Status.t() | nil
  def get_status_unchecked(nil), do: nil
  def get_status_unchecked(id), do: not_deleted() |> Repo.get(id)

  @doc """
  Fetches a status by its federation URI, regardless of who may read it.

  For the federation paths, which act on a document rather than on behalf of a
  reader. Never for rendering.

  One of ours is read out of the URI rather than looked up in a column: a post
  that started here has no `uri`, because the id this server publishes is
  derived from the row. Matching on the column answered `nil` for every local
  post, so an inbound `Like`, `Announce`, `Delete` or reply naming one of ours
  found nothing and was quietly dropped.
  """
  @spec get_status_unchecked_by_uri(String.t() | nil) :: Status.t() | nil
  def get_status_unchecked_by_uri(uri) when is_binary(uri) do
    case URIs.parse_local(uri) do
      {:status, id} -> local_status(id)
      :error -> Repo.get_by(Status, uri: uri)
      # A local URI in an account's shape names an account, not a post.
      _account -> nil
    end
  end

  def get_status_unchecked_by_uri(_uri), do: nil

  @doc """
  Fetches a status by its federation URI that `viewer` may read, or `nil`.

  The viewer-aware twin of `get_status_unchecked_by_uri/1`, for the one caller
  that renders what it finds: search resolves a pasted address, and reading it
  unchecked handed anybody holding the address of a followers-only post its
  full text with no account at all. Everything else that looks a URI up acts
  on a document rather than on behalf of a reader, and keeps the unchecked one.
  """
  @spec readable_by_uri(String.t() | nil, Account.t() | integer() | nil) :: Status.t() | nil
  def readable_by_uri(uri, viewer) do
    case get_status_unchecked_by_uri(uri) do
      %Status{id: id} -> readable(id, viewer)
      nil -> nil
    end
  end

  defp local_status(id) do
    case Repo.get(Status, id) do
      %Status{local: true} = status -> status
      _ -> nil
    end
  end

  @doc """
  Updates a status we hold on behalf of another server.

  Separate from `edit_status/2`, which snapshots a revision: a remote update is
  the peer telling us what the post says now, and their own edit history is
  theirs to serve, not ours to reconstruct.
  """
  @spec update_remote_status(Status.t(), map()) ::
          {:ok, Status.t()} | {:error, Ecto.Changeset.t()}
  def update_remote_status(%Status{} = status, attrs) do
    status |> Status.changeset(attrs) |> Repo.update()
  end

  @doc """
  The public timeline: the newest public posts, boosts and self-replies aside.

  The `where` here is written to match `statuses_public_timeline_index`
  predicate for predicate, so the whole page comes off that index.
  """
  @spec public_timeline(keyword()) :: [Status.t()]
  def public_timeline(opts \\ []) do
    public_timeline_scope()
    |> maybe_local_only(Keyword.get(opts, :local, false))
    |> maybe_language(Keyword.get(opts, :language))
    |> paginate(opts)
    |> Repo.all()
  end

  @doc """
  Narrows a query to what the public timeline shows: live public posts, no
  boosts, and no replies except a thread somebody spins themselves.

  The `where` is written to match `statuses_public_timeline_index` predicate
  for predicate, so a page of the timeline is a bounded scan off that index.
  Every reader of the public timeline — the API, the explore page, the landing
  page — goes through this one scope, so they cannot drift apart.
  """
  @spec public_timeline_scope() :: Ecto.Query.t()
  def public_timeline_scope do
    # The author check is a correlated probe rather than a join, so the page
    # still comes off the partial index and each candidate row costs one
    # primary-key lookup. Silenced and suspended authors stay out: a silence
    # is a moderator saying "not in front of strangers", and this is the
    # largest room of strangers there is.
    from s in Status,
      as: :status,
      where:
        is_nil(s.deleted_at) and
          s.visibility == :public and
          is_nil(s.reblog_of_id) and
          (is_nil(s.in_reply_to_id) or s.in_reply_to_account_id == s.account_id),
      where:
        not exists(
          from a in Account,
            where:
              a.id == parent_as(:status).account_id and
                (not is_nil(a.suspended_at) or not is_nil(a.silenced_at)),
            select: a.id
        )
  end

  defp maybe_local_only(query, false), do: query
  defp maybe_local_only(query, true), do: from(s in query, where: s.local == true)

  defp maybe_language(query, nil), do: query
  defp maybe_language(query, language), do: from(s in query, where: s.language == ^language)

  # Ids sort by creation time, so they are the cursor. See `Abuuba.Snowflake`.
  defp paginate(query, opts) do
    # Clamped at both ends. A negative limit reaches Postgres as LIMIT -1 and
    # errors; a zero one silently returns nothing, which reads as "no posts"
    # rather than as the bad request it is.
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(40)

    query
    |> then(fn q ->
      case Keyword.get(opts, :max_id) do
        nil -> q
        max_id -> from(s in q, where: s.id < ^max_id)
      end
    end)
    |> then(fn q ->
      case Keyword.get(opts, :since_id) do
        nil -> q
        since_id -> from(s in q, where: s.id > ^since_id)
      end
    end)
    |> order_by([s], desc: s.id)
    |> limit(^limit)
  end

  @doc """
  A thread's statuses, oldest first.
  """
  @spec conversation_statuses(Conversation.t() | integer(), Account.t() | integer() | nil) ::
          [Status.t()]
  def conversation_statuses(conversation, viewer)

  def conversation_statuses(%Conversation{id: id}, viewer),
    do: conversation_statuses(id, viewer)

  def conversation_statuses(conversation_id, viewer) do
    not_deleted()
    |> visible_to(viewer)
    |> where([s], s.conversation_id == ^conversation_id)
    |> order_by([s], asc: s.id)
    |> Repo.all()
  end

  ## Conversations

  @doc """
  Finds or creates the conversation for a remote thread URI, or starts a local
  one when given `nil`.
  """
  @spec upsert_conversation(String.t() | nil) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def upsert_conversation(nil),
    do: %Conversation{} |> Conversation.changeset(%{}) |> Repo.insert()

  def upsert_conversation(uri) do
    # One of our own names comes back to us whenever a peer replies to a thread
    # that started here. Creating a row for it would give this server two
    # conversations for one thread, which is the thing a conversation exists to
    # prevent.
    case URIs.conversation_id_from(uri) do
      nil -> find_or_start(uri)
      id -> ours(id, uri)
    end
  end

  defp find_or_start(uri) do
    case Repo.get_by(Conversation, uri: uri) do
      nil -> %Conversation{} |> Conversation.changeset(%{uri: uri}) |> Repo.insert()
      conversation -> {:ok, conversation}
    end
  end

  # A name of ours for a conversation that is no longer here — deleted, or from
  # a database this one replaced — is a name we cannot honour. Recording it as
  # somebody else's is better than inventing a local conversation with an id
  # that means something different.
  defp ours(id, uri) do
    case Repo.get(Conversation, id) do
      nil -> find_or_start(uri)
      conversation -> {:ok, conversation}
    end
  end

  @doc """
  The four things only a reader can answer about one post, for several readers
  at once.

  Four queries however many readers there are, which is what makes pushing one
  post to a room full of sockets cheap: the expensive half of the payload is
  the same for everybody, and this is the half that is not.
  """
  @spec reader_state(Status.t(), [integer()]) :: %{integer() => map()}
  def reader_state(status, account_ids)
  def reader_state(_status, []), do: %{}

  def reader_state(%Status{id: id, conversation_id: conversation_id}, account_ids) do
    favourited = own_ids(Favourite, id, account_ids)
    bookmarked = own_ids(Bookmark, id, account_ids)
    pinned = own_ids(Pin, id, account_ids)
    boosted = boosters(id, account_ids)
    muted = muted_conversation(conversation_id, account_ids)

    Map.new(account_ids, fn account_id ->
      {account_id,
       %{
         "favourited" => MapSet.member?(favourited, account_id),
         "reblogged" => MapSet.member?(boosted, account_id),
         "bookmarked" => MapSet.member?(bookmarked, account_id),
         "muted" => MapSet.member?(muted, account_id),
         "pinned" => MapSet.member?(pinned, account_id)
       }}
    end)
  end

  defp own_ids(schema, status_id, account_ids) do
    schema
    |> where([r], r.status_id == ^status_id and r.account_id in ^account_ids)
    |> select([r], r.account_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp boosters(status_id, account_ids) do
    Status
    |> where([s], s.reblog_of_id == ^status_id and s.account_id in ^account_ids)
    |> where([s], is_nil(s.deleted_at))
    |> select([s], s.account_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp muted_conversation(nil, _account_ids), do: MapSet.new()

  defp muted_conversation(conversation_id, account_ids) do
    ConversationMute
    |> where([c], c.conversation_id == ^conversation_id and c.account_id in ^account_ids)
    |> select([c], c.account_id)
    |> Repo.all()
    |> MapSet.new()
  end

  ## Mentions

  @doc """
  Records that a status addresses an account.
  """
  @spec mention(Status.t() | integer(), Account.t() | integer(), keyword()) ::
          {:ok, Mention.t()} | {:error, Ecto.Changeset.t()}
  def mention(status, account, opts \\ [])
  def mention(%Status{id: id}, account, opts), do: mention(id, account, opts)
  def mention(status_id, %Account{id: id}, opts), do: mention(status_id, id, opts)

  def mention(status_id, account_id, opts) do
    silent = Keyword.get(opts, :silent, false)

    result =
      %Mention{}
      |> Mention.changeset(%{
        status_id: status_id,
        account_id: account_id,
        silent: silent
      })
      |> Repo.insert()

    # Announced here rather than by each caller. The composer used to announce
    # its own and the inbound path did not, so being mentioned by somebody on
    # another server was silent -- the row was written, the notification was
    # not, and nothing said so. A mention that reaches nobody is the one kind
    # of post that has no other way of being found: it is what two strangers
    # have instead of a follow.
    #
    # A refused insert is a redelivery of a mention already recorded, so there
    # is nobody new to tell.
    with {:ok, _mention} <- result, false <- silent do
      notify_mentioned(status_id, account_id)
    end

    result
  end

  # A silent mention is the one a boost or a reply carries for addressing, not
  # for telling somebody they were talked to.
  defp notify_mentioned(status_id, account_id) do
    with %Status{} = status <- Repo.get(Status, status_id),
         %Account{} = account <- Repo.get(Account, account_id),
         true <- Account.local?(account),
         true <- account.id != status.account_id do
      Notifications.notify(account, status.account_id, "mention", status_id: status.id)
    end

    :ok
  end

  ## Tags

  @doc """
  Finds a tag by any spelling of its name, or creates it.
  """
  @spec upsert_tag(String.t()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t()}
  def upsert_tag(name) do
    case Repo.get_by(Tag, name: Tag.normalise(name)) do
      nil -> %Tag{} |> Tag.changeset(%{name: name}) |> Repo.insert()
      tag -> {:ok, tag}
    end
  end

  @doc """
  Files a status under a tag.
  """
  @spec tag_status(Status.t() | integer(), Tag.t() | integer()) :: :ok
  def tag_status(%Status{id: id}, tag), do: tag_status(id, tag)
  def tag_status(status_id, %Tag{id: id}), do: tag_status(status_id, id)

  def tag_status(status_id, tag_id) do
    Repo.insert_all(
      "statuses_tags",
      [[status_id: status_id, tag_id: tag_id]],
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  The newest statuses filed under a tag.
  """
  @spec tag_timeline(Tag.t() | integer(), keyword()) :: [Status.t()]
  def tag_timeline(tag, opts \\ [])
  def tag_timeline(%Tag{id: id}, opts), do: tag_timeline(id, opts)

  def tag_timeline(tag_id, opts) do
    not_deleted()
    |> visible_to(Keyword.get(opts, :viewer))
    |> join(:inner, [s], st in "statuses_tags", on: st.status_id == s.id)
    |> where([_s, st], st.tag_id == ^tag_id)
    |> paginate(opts)
    |> Repo.all()
  end

  ## Favourites and bookmarks

  @doc """
  Marks a status as a favourite.
  """
  @spec favourite(Account.t() | integer(), Status.t() | integer()) ::
          {:ok, Favourite.t()} | {:error, Ecto.Changeset.t()}
  def favourite(%Account{id: id}, status), do: favourite(id, status)
  def favourite(account_id, %Status{id: id}), do: favourite(account_id, id)

  def favourite(account_id, status_id) do
    # Row and counter in one transaction, so a concurrent unfavourite cannot
    # see the row, take the counter below zero, and trip its CHECK constraint
    # before the increment lands.
    Multi.new()
    |> Multi.insert(
      :favourite,
      Favourite.changeset(%Favourite{}, %{account_id: account_id, status_id: status_id})
    )
    |> Multi.run(:counters, fn _repo, _changes ->
      {:ok, Stats.bump_status(status_id, favourites_count: 1)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{favourite: favourite}} ->
        # Attention is what makes a post trend, rather than the author's own
        # act of writing it.
        Trends.record_interaction(status_id, account_id)

        notify_about(status_id, account_id, "favourite")
        Outbox.favourited(favourite)

        {:ok, favourite}

      {:error, :favourite, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Whether somebody has favourited a status.
  """
  @spec favourited?(integer(), integer()) :: boolean()
  def favourited?(account_id, status_id) do
    Favourite
    |> where([f], f.account_id == ^account_id and f.status_id == ^status_id)
    |> Repo.exists?()
  end

  @doc """
  Whether somebody has bookmarked a status.
  """
  @spec bookmarked?(integer(), integer()) :: boolean()
  def bookmarked?(account_id, status_id) do
    Bookmark
    |> where([b], b.account_id == ^account_id and b.status_id == ^status_id)
    |> Repo.exists?()
  end

  @doc """
  Whether somebody's boost of a status is still standing.
  """
  @spec boosted?(integer(), integer()) :: boolean()
  def boosted?(account_id, status_id) do
    Status
    |> where([s], s.account_id == ^account_id and s.reblog_of_id == ^status_id)
    |> where([s], is_nil(s.deleted_at))
    |> Repo.exists?()
  end

  @doc """
  Removes a favourite. `:ok` whether or not there was one, so a retried
  unfavourite is not an error for having succeeded already.
  """
  @spec unfavourite(Account.t() | integer(), Status.t() | integer()) :: :ok
  def unfavourite(%Account{id: id}, status), do: unfavourite(id, status)
  def unfavourite(account_id, %Status{id: id}), do: unfavourite(account_id, id)

  def unfavourite(account_id, status_id) do
    # Read before the delete. An `Undo` has to name the id of the `Like` the
    # peer stored, and that id is derived from the row, so a row that is
    # already gone leaves nothing to take back with.
    going = Repo.get_by(Favourite, account_id: account_id, status_id: status_id)

    {:ok, removed} =
      Repo.transaction(fn ->
        {removed, _} =
          Favourite
          |> where([f], f.account_id == ^account_id and f.status_id == ^status_id)
          |> Repo.delete_all()

        if removed > 0, do: Stats.bump_status(status_id, favourites_count: -removed)

        removed
      end)

    # On the delete rather than on the read, so a retried unfavourite that took
    # nothing away does not send a second `Undo`.
    if going && removed > 0 do
      notify_forget(status_id, account_id, "favourite")
      Outbox.unfavourited(going)
    end

    :ok
  end

  @doc """
  Removes a boost, soft-deleting the boost row.

  Soft rather than hard, like any other status: other servers may still hold
  the boost and a Delete for it may still be travelling.
  """
  @spec unboost(Account.t() | integer(), Status.t() | integer()) :: :ok
  def unboost(%Account{id: id}, status), do: unboost(id, status)
  def unboost(account_id, %Status{id: id}), do: unboost(account_id, id)

  def unboost(account_id, status_id) do
    # Through `delete_status/1`, because taking a boost back is deleting the
    # boost: the feeds it reached, the counters it moved and whoever is
    # watching a timeline all have to hear about it the same way. At most one
    # row matches — an account boosts a post once.
    Status
    |> where([s], s.account_id == ^account_id and s.reblog_of_id == ^status_id)
    |> where([s], is_nil(s.deleted_at))
    |> Repo.all()
    |> Enum.each(&delete_status/1)

    :ok
  end

  @doc """
  Whether somebody may boost a post.

  A boost carries a post to the booster's followers, who are not the audience
  the author chose, so being allowed to *read* a followers-only post is not the
  same permission as being allowed to republish it. Your own you may always
  boost: it reaches nobody it was not already addressed to.

  Asked at the point a person clicks the button rather than inside `boost/2`,
  because an inbound `Announce` is a peer telling us what already happened on
  their server. Refusing to record that would not unpublish anything; it would
  only make our copy of the thread wrong.
  """
  @spec boostable?(Account.t() | integer(), Status.t()) :: boolean()
  def boostable?(%Account{id: id}, status), do: boostable?(id, status)

  def boostable?(account_id, %Status{account_id: author_id, visibility: visibility}) do
    account_id == author_id or visibility in [:public, :unlisted]
  end

  @doc """
  Privately marks a status for later.
  """
  @spec bookmark(Account.t() | integer(), Status.t() | integer()) ::
          {:ok, Bookmark.t()} | {:error, Ecto.Changeset.t()}
  def bookmark(%Account{id: id}, status), do: bookmark(id, status)
  def bookmark(account_id, %Status{id: id}), do: bookmark(account_id, id)

  def bookmark(account_id, status_id) do
    %Bookmark{}
    |> Bookmark.changeset(%{account_id: account_id, status_id: status_id})
    |> Repo.insert()
  end

  ## Threads

  # Deep enough for any conversation a person is reading, and bounded because
  # a peer can build a chain thousands long. Truncating is the friendly answer:
  # a reader wants the nearby conversation, not a refusal.
  @max_thread_depth 40

  # The other bound: how many rows one thread may put into one answer. Depth
  # caps a chain; this caps a post with thousands of direct replies. The
  # oldest survive, which is where the conversation started.
  @max_thread_replies 4096

  @doc """
  How far a thread is walked in either direction.
  """
  @spec max_thread_depth() :: pos_integer()
  def max_thread_depth, do: @max_thread_depth

  @doc """
  The conversation around a status: everything above it and everything below.

  Both halves are one recursive query rather than a walk in Elixir, because a
  walk is one round trip per step and a busy thread is fifty of them. The depth
  bound is inside the query for the same reason, and it is what keeps a peer
  that sends a reply pointing at itself from hanging the request: the walk
  stops after `max_thread_depth/0` steps whatever the data says. The breadth
  bound (`:replies_limit`) is what keeps a post with ten thousand replies from
  answering with ten thousand rows.

  `viewer` is required and filters both halves. A thread is exactly where a
  private reply sits next to public ones, so a context that skipped the check
  would hand a stranger the one post in it they were not meant to read.
  """
  @spec context(Status.t(), Account.t() | integer() | nil, keyword()) :: %{
          ancestors: [Status.t()],
          descendants: [Status.t()]
        }
  def context(%Status{} = status, viewer, opts \\ []) do
    %{
      ancestors: ancestors(status, viewer),
      descendants:
        descendants(status, viewer, Keyword.get(opts, :replies_limit, @max_thread_replies))
    }
  end

  defp ancestors(%Status{in_reply_to_id: nil}, _viewer), do: []

  defp ancestors(%Status{} = status, viewer) do
    """
    WITH RECURSIVE thread AS (
      SELECT id, in_reply_to_id, 1 AS depth FROM statuses WHERE id = $1
      UNION ALL
      SELECT s.id, s.in_reply_to_id, thread.depth + 1
      FROM statuses s JOIN thread ON s.id = thread.in_reply_to_id
      WHERE thread.depth < $2
    )
    SELECT id FROM thread WHERE id <> $1
    """
    |> query_ids([status.id, @max_thread_depth])
    |> load_thread(viewer, :asc)
  end

  defp descendants(%Status{} = status, viewer, replies_limit) do
    """
    WITH RECURSIVE thread AS (
      SELECT id, 1 AS depth FROM statuses WHERE id = $1
      UNION ALL
      SELECT s.id, thread.depth + 1
      FROM statuses s JOIN thread ON s.in_reply_to_id = thread.id
      WHERE thread.depth < $2
    )
    SELECT id FROM thread WHERE id <> $1 ORDER BY id LIMIT $3
    """
    |> query_ids([status.id, @max_thread_depth, replies_limit])
    |> load_thread(viewer, :asc)
  end

  defp query_ids(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn [id] -> id end)
  end

  # The ids come back from the walk; the rows come back through the ordinary
  # filters. Selecting the rows inside the recursive query would mean writing
  # the visibility rules a second time, in SQL, where nothing checks them.
  defp load_thread([], _viewer, _order), do: []

  defp load_thread(ids, viewer, order) do
    not_deleted()
    |> visible_to(viewer)
    # A thread is where a block is most visible: open the post and there they
    # are, replying. Both questions, as everywhere else -- may this be read,
    # and are these two on speaking terms.
    |> excluding_hidden(viewer)
    |> where([s], s.id in ^ids)
    |> order_by([s], [{^order, s.id}])
    |> Repo.all()
  end

  ## Pinned posts

  # As many as the reference implementation allows. The bound is also what
  # keeps a profile page a page: everything pinned renders above the posts.
  @max_pins 5

  @doc """
  How many posts one profile may pin.
  """
  @spec max_pins() :: pos_integer()
  def max_pins, do: @max_pins

  @doc """
  Puts one of an account's own public posts at the top of its profile.

  Only its own, and only public: everybody who visits a profile sees what is
  pinned there, so pinning a followers-only post would publish it to people it
  was never addressed to. A boost is refused for the first reason, since the
  post it carries belongs to somebody else.
  """
  @spec pin(Account.t(), Status.t()) ::
          {:ok, Pin.t()} | {:error, :not_yours | :not_public | :too_many | Ecto.Changeset.t()}
  def pin(%Account{} = account, %Status{} = status) do
    cond do
      status.account_id != account.id or not is_nil(status.reblog_of_id) ->
        {:error, :not_yours}

      status.visibility not in [:public, :unlisted] ->
        {:error, :not_public}

      pins_full?(account.id, status.id) ->
        {:error, :too_many}

      true ->
        %Pin{}
        |> Pin.changeset(%{account_id: account.id, status_id: status.id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:account_id, :status_id])
        |> pinned_result(account, status)
        |> tap(fn
          {:ok, _pin} -> Outbox.pinned(account, status)
          _ -> :ok
        end)
    end
  end

  # `on_conflict: :nothing` hands back a struct with no id, which is not
  # something a caller can use. A client retrying a pin is asking for the state
  # it already has, so it gets the row.
  defp pinned_result({:ok, %Pin{id: nil}}, account, status) do
    {:ok, Repo.get_by!(Pin, account_id: account.id, status_id: status.id)}
  end

  defp pinned_result(result, _account, _status), do: result

  # One read answers both questions: is the board full, and is this post
  # already on it (a retried pin of the fifth post is not a sixth pin).
  defp pins_full?(account_id, status_id) do
    pinned =
      Pin
      |> where([p], p.account_id == ^account_id)
      |> select([p], p.status_id)
      |> Repo.all()

    length(pinned) >= @max_pins and status_id not in pinned
  end

  @doc """
  Takes a post back off a profile. Not an error if it was never there.
  """
  @spec unpin(Account.t(), Status.t()) :: :ok
  def unpin(%Account{} = account, %Status{} = status) do
    {removed, _} =
      Pin
      |> where([p], p.account_id == ^account.id and p.status_id == ^status.id)
      |> Repo.delete_all()

    # Only when something was actually taken off the board, so a retried unpin
    # does not send a second `Remove`.
    if removed > 0, do: Outbox.unpinned(account, status)

    :ok
  end

  @doc """
  The languages an account has actually posted in, commonest first.

  For the language filter on a follow, which is a choice about somebody else's
  posts. Offering every language this server knows would be a list of a hundred
  where two of them are the answer, and the two are knowable: they are what
  that account has been writing in.
  """
  @spec languages_used_by(Account.t() | integer()) :: [String.t()]
  def languages_used_by(%Account{id: id}), do: languages_used_by(id)

  def languages_used_by(account_id) do
    Status
    |> where([s], s.account_id == ^account_id and not is_nil(s.language))
    |> where([s], is_nil(s.deleted_at))
    |> group_by([s], s.language)
    |> order_by([s], desc: count(s.id), asc: s.language)
    |> select([s], s.language)
    |> Repo.all()
  end

  @doc """
  An account's pinned posts, newest pin first.
  """
  @spec pinned(Account.t() | integer()) :: [Status.t()]
  def pinned(account, viewer \\ nil)

  def pinned(%Account{id: id}, viewer), do: pinned(id, viewer)

  def pinned(account_id, viewer) do
    if blocked_reader?(account_id, viewer) do
      []
    else
      pinned_query(account_id, viewer)
    end
  end

  defp pinned_query(account_id, viewer) do
    not_deleted()
    # Whoever is asking, rather than whoever pinned it: a pinned post that is
    # followers-only is still followers-only, and a profile is the place a
    # stranger is most likely to be looking.
    |> visible_to(viewer)
    |> join(:inner, [s], p in Pin, on: p.status_id == s.id)
    |> where([_s, p], p.account_id == ^account_id)
    |> order_by([_s, p], desc: p.id)
    |> Repo.all()
  end

  ## Muted threads

  @doc """
  Stops telling somebody about a thread, including the parts of it nobody has
  written yet.
  """
  @spec mute_thread(Account.t(), Status.t()) ::
          {:ok, ConversationMute.t()} | {:error, :no_conversation | Ecto.Changeset.t()}
  def mute_thread(_account, %Status{conversation_id: nil}), do: {:error, :no_conversation}

  def mute_thread(%Account{id: account_id}, %Status{conversation_id: conversation_id}) do
    %ConversationMute{}
    |> ConversationMute.changeset(%{account_id: account_id, conversation_id: conversation_id})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:account_id, :conversation_id],
      returning: true
    )
    |> case do
      {:ok, %ConversationMute{id: nil}} ->
        {:ok,
         Repo.get_by!(ConversationMute, account_id: account_id, conversation_id: conversation_id)}

      result ->
        result
    end
  end

  @doc """
  Starts telling them about it again.
  """
  @spec unmute_thread(Account.t(), Status.t()) :: :ok
  def unmute_thread(_account, %Status{conversation_id: nil}), do: :ok

  def unmute_thread(%Account{id: account_id}, %Status{conversation_id: conversation_id}) do
    ConversationMute
    |> where([m], m.account_id == ^account_id and m.conversation_id == ^conversation_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Whether somebody has muted the thread a status is part of.
  """
  @spec thread_muted?(Account.t() | integer() | nil, Status.t()) :: boolean()
  def thread_muted?(nil, _status), do: false
  def thread_muted?(_account, %Status{conversation_id: nil}), do: false
  def thread_muted?(%Account{id: id}, status), do: thread_muted?(id, status)

  def thread_muted?(account_id, %Status{conversation_id: conversation_id}) do
    ConversationMute
    |> where([m], m.account_id == ^account_id and m.conversation_id == ^conversation_id)
    |> Repo.exists?()
  end

  ## Idempotency

  # Long enough to outlast any client's retry, short enough that the table is
  # a buffer rather than a log.
  @idempotency_window_seconds 60 * 60

  @doc """
  Records which post a client's `Idempotency-Key` produced.
  """
  @spec remember_key(Account.t() | integer(), String.t(), Status.t() | ScheduledStatus.t()) :: :ok
  def remember_key(%Account{id: id}, key, made), do: remember_key(id, key, made)

  def remember_key(account_id, key, %Status{id: status_id}),
    do: remember_key(account_id, key, %{status_id: status_id})

  def remember_key(account_id, key, %ScheduledStatus{id: scheduled_id}),
    do: remember_key(account_id, key, %{scheduled_status_id: scheduled_id})

  def remember_key(account_id, key, made) when is_map(made) do
    %IdempotencyKey{}
    |> IdempotencyKey.changeset(Map.merge(made, %{account_id: account_id, key: key}))
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:account_id, :key])

    :ok
  end

  @doc """
  The post a client already made with this key, if it is recent enough to be a
  retry rather than a coincidence.
  """
  @spec replay_key(Account.t() | integer(), String.t() | nil) ::
          Status.t() | ScheduledStatus.t() | nil
  def replay_key(_account, nil), do: nil
  def replay_key(%Account{id: id}, key), do: replay_key(id, key)

  def replay_key(account_id, key) when is_binary(key) do
    cutoff = DateTime.add(DateTime.utc_now(), -@idempotency_window_seconds, :second)

    IdempotencyKey
    |> where([k], k.account_id == ^account_id and k.key == ^key)
    |> where([k], k.inserted_at > ^cutoff)
    |> select([k], {k.status_id, k.scheduled_status_id})
    |> Repo.one()
    |> case do
      nil -> nil
      {nil, nil} -> nil
      {nil, scheduled_id} -> Repo.get(ScheduledStatus, scheduled_id)
      {status_id, _scheduled} -> get_status_unchecked(status_id)
    end
  end

  def replay_key(_account, _key), do: nil

  @doc """
  Forgets keys too old to be anybody's retry.
  """
  @spec sweep_idempotency_keys() :: {non_neg_integer(), nil}
  def sweep_idempotency_keys do
    cutoff = DateTime.add(DateTime.utc_now(), -@idempotency_window_seconds, :second)

    IdempotencyKey |> where([k], k.inserted_at <= ^cutoff) |> Repo.delete_all()
  end

  ## Polls

  @doc """
  Attaches a poll to a status.
  """
  @spec create_poll(Status.t(), map()) :: {:ok, Poll.t()} | {:error, Ecto.Changeset.t()}
  def create_poll(%Status{} = status, attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"status_id" => status.id, "account_id" => status.account_id})

    %Poll{} |> Poll.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Puts the poll a remote post arrived with in place of whatever we held.

  `nil` removes it, because an author who edited the poll away has to see it go
  here too rather than leave the post offering a vote they withdrew.

  Updating rather than replacing where one already exists: the row is what our
  own users' votes point at, and a poll rebuilt from scratch on every refresh
  would take those with it. Only what the sender is authoritative about moves
  -- the options, the counts and the deadline.
  """
  @spec replace_remote_poll(Status.t(), map() | nil) :: :ok
  def replace_remote_poll(%Status{} = status, nil) do
    case get_poll(status) do
      nil -> :ok
      poll -> Repo.delete(poll) && :ok
    end
  end

  def replace_remote_poll(%Status{} = status, attrs) do
    attrs = Map.merge(attrs, %{status_id: status.id, account_id: status.account_id})

    result =
      case get_poll(status) do
        nil -> %Poll{} |> Poll.remote_changeset(attrs) |> Repo.insert()
        poll -> poll |> Poll.remote_changeset(attrs) |> Repo.update()
      end

    # A poll we cannot make sense of is not a reason to lose the post it came
    # with, so a rejected changeset leaves the status alone.
    case result do
      {:ok, _poll} -> :ok
      {:error, _changeset} -> :ok
    end
  end

  @doc """
  The poll on a status, or `nil`.
  """
  @spec get_poll(Status.t() | integer()) :: Poll.t() | nil
  def get_poll(%Status{id: id}), do: get_poll(id)
  def get_poll(status_id), do: Repo.get_by(Poll, status_id: status_id)

  @doc """
  A poll by its own id, or `nil`.

  Distinct from `get_poll/1`, which takes the post the poll belongs to. A
  ballot names the poll rather than the post, and the two ids are easy to hand
  to the wrong one of these: a lookup by the other's id quietly finds nothing,
  so the vote is refused and the voter is told the poll could not be counted.
  """
  @spec fetch_poll(String.t() | integer()) :: Poll.t() | nil
  def fetch_poll(id) when is_integer(id), do: Repo.get(Poll, id)

  def fetch_poll(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} -> fetch_poll(number)
      _ -> nil
    end
  end

  def fetch_poll(_id), do: nil

  @doc """
  Records somebody's answer, or answers, and returns the poll as it now reads.

  The tallies are kept on the poll rather than counted per render, so the write
  is what has to be careful: the votes and the counters move in one transaction
  and the unique index on `(poll, account, choice)` is what makes a double
  submission a refusal rather than a double count.
  """
  @spec vote(Poll.t(), Account.t(), [integer()]) ::
          {:ok, Poll.t()}
          | {:error, :expired | :own_poll | :already_voted | :invalid_choice | :too_many_choices}
  def vote(%Poll{} = poll, %Account{} = voter, choices) do
    with :ok <- check_open(poll),
         :ok <- check_not_author(poll, voter),
         :ok <- check_choices(poll, choices),
         :ok <- check_not_voted(poll, voter) do
      choices = Enum.uniq(choices)

      with {:ok, updated} <- record_votes(poll, voter, choices) do
        # The server that owns the poll keeps the count everybody reads, so a
        # vote it never hears about is a vote that did not happen. Nothing is
        # sent for a poll of our own; the outbox refuses a local target.
        Outbox.voted(poll, voter, choices)

        {:ok, updated}
      end
    end
  end

  @doc """
  Records a vote that arrived from another server, one choice at a time.

  Separate from `vote/3` because of how a multiple-choice poll travels: a peer
  sends one activity per option chosen, so the second arrival must not read as
  somebody voting twice, and must not make them two voters either. `vote/3`
  takes every choice at once, which is what a client here does, and refuses a
  second submission outright -- correct there and wrong for this.

  The same choice arriving again is a redelivery and counts once.
  """
  @spec record_remote_vote(Poll.t(), Account.t(), integer()) ::
          {:ok, Poll.t()} | {:error, :expired | :own_poll | :already_voted | :invalid_choice}
  def record_remote_vote(%Poll{} = poll, %Account{} = voter, choice) do
    with :ok <- check_open(poll),
         :ok <- check_not_author(poll, voter),
         :ok <- check_choices(poll, [choice]) do
      case own_votes(poll, voter) do
        [] -> record_votes(poll, voter, [choice])
        already -> add_choice(poll, voter, choice, already)
      end
    end
  end

  # Somebody who has already voted here. On a single-choice poll that is the
  # end of it; on a multiple-choice one this is the next option of the same
  # vote, so the tally moves and the voter count does not.
  defp add_choice(%Poll{multiple: false}, _voter, _choice, _already), do: {:error, :already_voted}

  defp add_choice(%Poll{} = poll, voter, choice, already) do
    if choice in already do
      {:error, :already_voted}
    else
      Multi.new()
      |> Multi.insert_all(
        :votes,
        PollVote,
        [
          %{
            poll_id: poll.id,
            account_id: voter.id,
            choice: choice,
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:poll_id, :account_id, :choice]
      )
      |> Multi.run(:tally, fn repo, _changes ->
        locked = Poll |> where([p], p.id == ^poll.id) |> lock("FOR UPDATE") |> repo.one!()

        repo.update(Ecto.Changeset.change(locked, tallies: bump(locked.tallies, [choice])))
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{tally: poll}} -> {:ok, poll}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Which options somebody picked, in the order the poll lists them.
  """
  @spec own_votes(Poll.t(), Account.t() | integer() | nil) :: [integer()]
  def own_votes(_poll, nil), do: []
  def own_votes(poll, %Account{id: id}), do: own_votes(poll, id)

  def own_votes(%Poll{id: poll_id}, account_id) do
    PollVote
    |> where([v], v.poll_id == ^poll_id and v.account_id == ^account_id)
    |> select([v], v.choice)
    |> order_by([v], asc: v.choice)
    |> Repo.all()
  end

  @doc """
  Somebody's choices across several polls at once, keyed by poll id.

  One query for a page of polls; `own_votes/2` is the single-poll ask.
  """
  @spec own_votes_by_poll([Poll.t()], Account.t() | nil) :: %{integer() => [integer()]}
  def own_votes_by_poll([], _viewer), do: %{}
  def own_votes_by_poll(_polls, nil), do: %{}

  def own_votes_by_poll(polls, %Account{id: account_id}) do
    poll_ids = Enum.map(polls, & &1.id)

    PollVote
    |> where([v], v.poll_id in ^poll_ids and v.account_id == ^account_id)
    |> select([v], {v.poll_id, v.choice})
    |> order_by([v], asc: v.choice)
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp check_open(poll), do: if(Poll.expired?(poll), do: {:error, :expired}, else: :ok)

  # The reference implementation refuses this too. A poll is a question you
  # asked; answering it yourself is not something any client offers.
  defp check_not_author(%Poll{account_id: id}, %Account{id: id}), do: {:error, :own_poll}
  defp check_not_author(_poll, _voter), do: :ok

  defp check_choices(_poll, []), do: {:error, :invalid_choice}

  defp check_choices(%Poll{options: options, multiple: multiple}, choices) do
    cond do
      not Enum.all?(choices, &(is_integer(&1) and &1 >= 0 and &1 < length(options))) ->
        {:error, :invalid_choice}

      not multiple and length(Enum.uniq(choices)) > 1 ->
        {:error, :too_many_choices}

      true ->
        :ok
    end
  end

  defp check_not_voted(%Poll{id: poll_id}, %Account{id: account_id}) do
    PollVote
    |> where([v], v.poll_id == ^poll_id and v.account_id == ^account_id)
    |> Repo.exists?()
    |> case do
      true -> {:error, :already_voted}
      false -> :ok
    end
  end

  defp record_votes(poll, voter, choices) do
    now = DateTime.utc_now()

    rows =
      Enum.map(choices, fn choice ->
        %{
          poll_id: poll.id,
          account_id: voter.id,
          choice: choice,
          inserted_at: now,
          updated_at: now
        }
      end)

    Multi.new()
    |> Multi.insert_all(:votes, PollVote, rows,
      on_conflict: :nothing,
      conflict_target: [:poll_id, :account_id, :choice]
    )
    # Locked, then read, then written. The tallies live on the row rather than
    # being counted per render, so two people voting at once would otherwise
    # both read the same numbers and one of the two votes would vanish.
    |> Multi.run(:tally, fn repo, _changes ->
      locked =
        Poll
        |> where([p], p.id == ^poll.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      repo.update(
        Ecto.Changeset.change(locked,
          tallies: bump(locked.tallies, choices),
          voters_count: locked.voters_count + 1
        )
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{tally: poll}} -> {:ok, poll}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp bump(tallies, choices) do
    Enum.reduce(choices, tallies, fn choice, acc ->
      List.update_at(acc, choice, &((&1 || 0) + 1))
    end)
  end

  ## Drafts

  @doc """
  Keeps what somebody has written but not sent.

  Pass the draft being written to update it; pass nothing to start a new one.
  Autosave runs while somebody types, so without that distinction a sentence
  becomes a drafts list nobody can use.
  """
  @spec save_draft(Account.t() | integer(), map(), Draft.t() | nil) ::
          {:ok, Draft.t()} | {:error, :empty | :too_many | Ecto.Changeset.t()}
  def save_draft(account, params, draft \\ nil)
  def save_draft(%Account{id: id}, params, draft), do: save_draft(id, params, draft)

  def save_draft(account_id, params, draft) do
    cond do
      not Draft.worth_keeping?(params) ->
        {:error, :empty}

      # Only a new one is refused. Stopping the autosave of the draft somebody
      # is in the middle of writing would be a worse failure than the pile the
      # limit exists to prevent.
      is_nil(draft) and draft_count(account_id) >= Draft.limit() ->
        {:error, :too_many}

      true ->
        (draft || %Draft{})
        |> Draft.changeset(%{account_id: account_id, params: params})
        |> Repo.insert_or_update()
    end
  end

  @doc """
  An account's drafts, the one most recently written first.
  """
  @spec drafts(Account.t() | integer()) :: [Draft.t()]
  def drafts(%Account{id: id}), do: drafts(id)

  def drafts(account_id) do
    Draft
    |> where([d], d.account_id == ^account_id)
    |> order_by([d], desc: d.updated_at, desc: d.id)
    |> Repo.all()
  end

  @doc """
  One of an account's own drafts, or `nil`.

  Scoped by account in the query rather than checked afterwards: one that
  cannot return a stranger's row cannot leak one.
  """
  @spec get_draft(Account.t() | integer(), integer() | String.t()) :: Draft.t() | nil
  def get_draft(%Account{id: id}, draft_id), do: get_draft(id, draft_id)

  def get_draft(account_id, draft_id) do
    Repo.get_by(Draft, id: draft_id, account_id: account_id)
  end

  @doc """
  Forgets a draft.
  """
  @spec discard_draft(Draft.t()) :: {:ok, Draft.t()} | {:error, Ecto.Changeset.t()}
  def discard_draft(%Draft{} = draft), do: Repo.delete(draft)

  defp draft_count(account_id) do
    Draft |> where([d], d.account_id == ^account_id) |> Repo.aggregate(:count)
  end

  ## Scheduled posts

  @doc """
  Keeps a post to publish later.
  """
  @spec schedule(Account.t(), map(), DateTime.t()) ::
          {:ok, ScheduledStatus.t()} | {:error, Ecto.Changeset.t()}
  def schedule(%Account{id: account_id}, params, %DateTime{} = at) do
    with :ok <- publishable(account_id, params) do
      %ScheduledStatus{}
      |> ScheduledStatus.changeset(%{
        account_id: account_id,
        scheduled_at: at,
        params: params,
        media_attachment_ids: Map.get(params, "media_ids", [])
      })
      |> ScheduledStatus.validate_room(waiting(account_id), waiting(account_id, at))
      |> Repo.insert()
    end
  end

  # The same two changesets `publish_scheduled/1` will run, run now with
  # nothing inserted. Scheduling used to check only the queue limits, and
  # publication checks everything -- so a post the changeset would refuse
  # scheduled cleanly and was then dropped by the worker while its author
  # slept, a server log line the only trace. The refusal has to happen while
  # the person is still looking at the compose box.
  #
  # Mirrors `publish_scheduled/1` and `attach_scheduled_poll/2` field for
  # field, and any divergence between this and those is a bug here: the
  # question this answers is precisely "what will publication do".
  defp publishable(account_id, params) do
    status_changeset =
      Status.changeset(
        %Status{},
        params
        |> Map.take(~w(text spoiler_text language sensitive visibility quote_policy
                       in_reply_to_id in_reply_to_account_id conversation_id))
        |> Map.put("account_id", account_id)
      )

    poll_changeset = scheduled_poll_dry_run(account_id, params["poll"])

    cond do
      not status_changeset.valid? -> {:error, %{status_changeset | action: :insert}}
      poll_changeset && not poll_changeset.valid? -> {:error, %{poll_changeset | action: :insert}}
      true -> :ok
    end
  end

  defp scheduled_poll_dry_run(_account_id, poll) when not is_map(poll), do: nil

  defp scheduled_poll_dry_run(account_id, poll) do
    # The ids publication will supply, stood in for here so their absence
    # cannot mask a real problem with the options.
    Poll.changeset(%Poll{}, %{
      "status_id" => 0,
      "account_id" => account_id,
      "options" => poll["options"] || [],
      "multiple" => poll["multiple"] == true,
      "expires_at" => DateTime.add(DateTime.utc_now(), scheduled_poll_seconds(poll), :second)
    })
  end

  # A scheduled poll's expiry, whatever spelling it was stored in. The compose
  # endpoint stores its params as they arrived, so a form-encoded client's
  # `expires_in` is the string "3600" -- and publication handed that straight
  # to `DateTime.add/3`, which does not take strings. One such poll crashed
  # the publish worker, and the worker publishes everything due in one run, so
  # one person's malformed poll held up everybody's posts. Clamped to the same
  # bounds the immediate path clamps to, which scheduled polls never were.
  defp scheduled_poll_seconds(poll) do
    parsed =
      case poll["expires_in"] do
        n when is_integer(n) -> n
        s when is_binary(s) -> with(:error <- Integer.parse(s), do: {86_400, ""}) |> elem(0)
        _absent -> 86_400
      end

    parsed
    |> max(Poll.min_expiration_seconds())
    |> min(Poll.max_expiration_seconds())
  end

  # Counted rather than kept as a column: the numbers are small, the query is
  # indexed on `(account_id, scheduled_at)`, and a counter maintained alongside
  # the rows is a counter that drifts every time one is cancelled.
  defp waiting(account_id) do
    ScheduledStatus |> where([s], s.account_id == ^account_id) |> Repo.aggregate(:count)
  end

  defp waiting(account_id, %DateTime{} = at) do
    day = DateTime.to_date(at)

    ScheduledStatus
    |> where([s], s.account_id == ^account_id)
    |> where([s], fragment("(? at time zone 'UTC')::date", s.scheduled_at) == ^day)
    |> Repo.aggregate(:count)
  end

  @doc """
  Moves a scheduled post to a different time.
  """
  @spec reschedule(ScheduledStatus.t(), DateTime.t()) ::
          {:ok, ScheduledStatus.t()} | {:error, Ecto.Changeset.t()}
  def reschedule(%ScheduledStatus{} = scheduled, %DateTime{} = at) do
    scheduled |> ScheduledStatus.changeset(%{scheduled_at: at}) |> Repo.update()
  end

  @doc """
  Forgets a scheduled post.
  """
  @spec cancel_schedule(ScheduledStatus.t()) ::
          {:ok, ScheduledStatus.t()} | {:error, Ecto.Changeset.t()}
  def cancel_schedule(%ScheduledStatus{} = scheduled), do: Repo.delete(scheduled)

  @doc """
  An account's scheduled posts, soonest first.
  """
  @spec scheduled(Account.t() | integer()) :: [ScheduledStatus.t()]
  def scheduled(%Account{id: id}), do: scheduled(id)

  def scheduled(account_id) do
    ScheduledStatus
    |> where([s], s.account_id == ^account_id)
    |> order_by([s], asc: s.scheduled_at)
    |> Repo.all()
  end

  @doc """
  One scheduled post, or `nil`.
  """
  @spec get_scheduled(Account.t() | integer(), integer()) :: ScheduledStatus.t() | nil
  def get_scheduled(%Account{id: account_id}, id), do: get_scheduled(account_id, id)

  def get_scheduled(account_id, id) do
    Repo.get_by(ScheduledStatus, id: id, account_id: account_id)
  end

  @doc """
  Everything whose time has come.
  """
  @spec due_schedules(DateTime.t()) :: [ScheduledStatus.t()]
  def due_schedules(now \\ DateTime.utc_now()) do
    ScheduledStatus
    |> where([s], s.scheduled_at <= ^now)
    |> order_by([s], asc: s.scheduled_at)
    |> Repo.all()
  end

  @doc """
  Turns a scheduled post into a real one and forgets the schedule.

  Both in one transaction: a schedule left behind after publishing would
  publish again on the next sweep, and the person would have said the same
  thing twice for a reason nobody could see.
  """
  @spec publish_scheduled(ScheduledStatus.t()) ::
          {:ok, Status.t()} | {:error, Ecto.Changeset.t()}
  def publish_scheduled(%ScheduledStatus{} = scheduled) do
    attrs =
      scheduled.params
      |> Map.take(~w(text spoiler_text language sensitive visibility quote_policy
                     in_reply_to_id in_reply_to_account_id conversation_id))
      |> Map.put("account_id", scheduled.account_id)

    Multi.new()
    |> Multi.insert(:status, Status.changeset(%Status{}, attrs))
    |> Multi.delete(:schedule, scheduled)
    |> Multi.run(:counters, fn _repo, %{status: status} ->
      {:ok, count_status(status, 1)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{status: status}} ->
        # The ids were kept on the row from the moment it was scheduled, and
        # then thrown away here: a post written with a picture went out
        # without one, and the upload sat unattached until the sweep took it.
        status = attach_scheduled_media(status, scheduled.media_attachment_ids)
        attach_scheduled_poll(status, scheduled.params["poll"])

        # The whole `announce/1`, not just the linking: a post published on a
        # timer is a new post the moment it goes out — it belongs in
        # followers' feeds, in the trends, and on the screens of whoever is
        # watching, exactly as if its author had pressed send themselves.
        {:ok, announce(status)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Outside the transaction and never fatal. The post is the thing somebody
  # wrote; refusing to publish it because its poll turned out malformed would
  # lose both, and there is nobody at the keyboard to fix it at that hour.
  #
  # The clock starts when the post goes out rather than when it was written: a
  # poll scheduled for next week should run for a day from next week.
  defp attach_scheduled_media(status, []), do: status

  defp attach_scheduled_media(status, ids) do
    # Never fatal, for the reason the poll below is not: the post is the thing
    # somebody wrote, and refusing to publish it because an upload was swept
    # away in the meantime would lose the words as well as the picture.
    case Abuuba.Media.attach(status, ids) do
      {:ok, attached} -> attached
      {:error, _reason} -> status
    end
  end

  defp attach_scheduled_poll(_status, poll) when not is_map(poll), do: :ok

  defp attach_scheduled_poll(status, poll) do
    case create_poll(status, %{
           options: poll["options"] || [],
           multiple: poll["multiple"] == true,
           expires_at: DateTime.add(DateTime.utc_now(), scheduled_poll_seconds(poll), :second)
         }) do
      {:ok, _poll} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "scheduled poll for #{status.id} was dropped: #{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  @doc """
  Takes a bookmark back off. Not an error if it was never there.
  """
  @spec unbookmark(Account.t() | integer(), Status.t() | integer()) :: :ok
  def unbookmark(%Account{id: id}, status), do: unbookmark(id, status)
  def unbookmark(account_id, %Status{id: id}), do: unbookmark(account_id, id)

  def unbookmark(account_id, status_id) do
    Bookmark
    |> where([b], b.account_id == ^account_id and b.status_id == ^status_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  The direct replies to a post that are public enough to hand another server,
  oldest first.

  `:by` picks whose. `:author` is the post's own author, which is how a thread
  written by one person reads and so is what a peer wants first; `:others` is
  everybody else, and leaves out accounts this server has suspended, because
  publishing their replies is the thing suspending them was meant to stop.

  Walked forward by `:min_id` rather than by page number. A thread grows while
  it is being read, so a page number moves under the reader and an id does not.
  """
  @spec published_replies(Status.t(), keyword()) :: [Status.t()]
  def published_replies(%Status{id: id, account_id: author_id}, opts) do
    not_deleted()
    |> where([s], s.in_reply_to_id == ^id and s.visibility in [:public, :unlisted])
    |> repliers(author_id, Keyword.fetch!(opts, :by))
    |> then(fn query ->
      case Keyword.get(opts, :min_id) do
        nil -> query
        min_id -> where(query, [s], s.id > ^min_id)
      end
    end)
    |> order_by([s], asc: s.id)
    |> limit(^Keyword.fetch!(opts, :limit))
    |> Repo.all()
  end

  defp repliers(query, author_id, :author), do: where(query, [s], s.account_id == ^author_id)

  defp repliers(query, author_id, :others) do
    query
    |> join(:inner, [s], a in Account, on: a.id == s.account_id)
    |> where([s, a], s.account_id != ^author_id and is_nil(a.suspended_at))
  end

  @doc """
  Who boosted a post, newest first.
  """
  @spec boosted_by(Status.t(), map()) :: [Account.t()]
  def boosted_by(%Status{id: status_id}, page \\ %{}) do
    Status
    |> join(:inner, [s], a in Account, on: a.id == s.account_id)
    |> where([s], s.reblog_of_id == ^status_id and is_nil(s.deleted_at))
    |> select([_s, a], a)
    |> paginate_accounts(page)
  end

  @doc """
  Who favourited a post, newest first.
  """
  @spec favourited_by(Status.t(), map()) :: [Account.t()]
  def favourited_by(%Status{id: status_id}, page \\ %{}) do
    Favourite
    |> join(:inner, [f], a in Account, on: a.id == f.account_id)
    |> where([f], f.status_id == ^status_id)
    |> select([_f, a], a)
    |> paginate_accounts(page)
  end

  # The cursor is the account id, because that is what the client gets back
  # and what it will send in the next request. Windowed and ordered on the
  # owning row's copy of it rather than the joined account's: the two are
  # equal by the join, but only the owning column sits in the index that
  # serves the scan, and Postgres never pushes an inequality through a join.
  defp paginate_accounts(query, page) do
    limit = Map.get(page, :limit, 40)

    query
    |> maybe_before(Map.get(page, :max_id))
    |> maybe_after(Map.get(page, :min_id) || Map.get(page, :since_id))
    |> order_by([r, _a], [{^Pagination.direction(page), r.account_id}])
    |> limit(^limit)
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  defp maybe_before(query, nil), do: query
  defp maybe_before(query, id), do: where(query, [r, _a], r.account_id < ^id)

  defp maybe_after(query, nil), do: query
  defp maybe_after(query, id), do: where(query, [r, _a], r.account_id > ^id)

  @doc """
  One account's posts, newest first, as a particular reader may see them.

  Boosts and replies are included by default and excluded on request, which is
  what the tabs on a profile are asking for.
  """
  @spec account_timeline(Account.t() | integer(), Account.t() | integer() | nil, map()) ::
          [Status.t()]
  def account_timeline(account, viewer, page \\ %{})

  def account_timeline(%Account{id: id}, viewer, page), do: account_timeline(id, viewer, page)

  def account_timeline(account_id, viewer, page) do
    if blocked_reader?(account_id, viewer) do
      []
    else
      account_timeline_query(account_id, viewer, page)
    end
  end

  defp account_timeline_query(account_id, viewer, page) do
    not_deleted()
    |> visible_to(viewer)
    |> excluding_boosts_of_hidden(viewer)
    |> where([s], s.account_id == ^account_id)
    |> maybe_exclude_replies(Map.get(page, :exclude_replies, false))
    |> maybe_exclude_reblogs(Map.get(page, :exclude_reblogs, false))
    |> maybe_only_media(Map.get(page, :only_media, false))
    |> maybe_tagged(Map.get(page, :tagged))
    |> maybe_before_id(Map.get(page, :max_id))
    |> maybe_after_id(Map.get(page, :min_id) || Map.get(page, :since_id))
    |> order_by([s], [{^Pagination.direction(page), s.id}])
    |> limit(^Map.get(page, :limit, 20))
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  defp maybe_exclude_replies(query, true), do: where(query, [s], is_nil(s.in_reply_to_id))
  defp maybe_exclude_replies(query, _flag), do: query

  defp maybe_exclude_reblogs(query, true), do: where(query, [s], is_nil(s.reblog_of_id))
  defp maybe_exclude_reblogs(query, _flag), do: query

  # Asked of the database rather than filtered out of a page that was already
  # fetched: filtering after the fact turns a page of twenty into whatever
  # happened to carry a picture, which is neither twenty nor a page.
  defp maybe_only_media(query, true) do
    where(query, [s], fragment("array_length(?, 1) > 0", s.ordered_media_attachment_ids))
  end

  defp maybe_only_media(query, _flag), do: query

  # One person's posts under one hashtag, which is what a featured tag links to.
  defp maybe_tagged(query, nil), do: query

  defp maybe_tagged(query, name) do
    tagged =
      from(st in "statuses_tags",
        join: t in Tag,
        on: t.id == st.tag_id,
        where: t.name == ^Tag.normalise(name),
        select: st.status_id
      )

    where(query, [s], s.id in subquery(tagged))
  end

  defp maybe_before_id(query, nil), do: query
  defp maybe_before_id(query, id), do: where(query, [s], s.id < ^id)

  defp maybe_after_id(query, nil), do: query
  defp maybe_after_id(query, id), do: where(query, [s], s.id > ^id)

  @doc """
  What somebody favourited, newest mark first, as `%{mark_id, status}` rows.

  The mark id rides along because it is the cursor: the pages walk the order
  things were saved in, so a `Link` header built from post ids — snowflakes,
  from a different sequence entirely — would never advance.
  """
  @spec favourites(Account.t() | integer(), map()) :: [map()]
  def favourites(account, page \\ %{})
  def favourites(%Account{id: id}, page), do: favourites(id, page)

  def favourites(account_id, page) do
    marked(Favourite, account_id, page)
  end

  @doc """
  What somebody bookmarked, newest mark first, in the same shape as
  `favourites/2`.
  """
  @spec bookmarks(Account.t() | integer(), map()) :: [map()]
  def bookmarks(account, page \\ %{})
  def bookmarks(%Account{id: id}, page), do: bookmarks(id, page)

  def bookmarks(account_id, page) do
    marked(Bookmark, account_id, page)
  end

  # Paged on the mark rather than on the post: what a client is walking is the
  # order things were saved in, not the order they were written.
  defp marked(schema, account_id, page) do
    not_deleted()
    |> join(:inner, [s], m in ^schema, on: m.status_id == s.id)
    |> where([_s, m], m.account_id == ^account_id)
    |> maybe_mark_before(Map.get(page, :max_id))
    |> maybe_mark_after(Map.get(page, :min_id) || Map.get(page, :since_id))
    |> order_by([_s, m], [{^Pagination.direction(page), m.id}])
    |> limit(^Map.get(page, :limit, 20))
    |> select([s, m], %{mark_id: m.id, status: s})
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  defp maybe_mark_before(query, nil), do: query
  defp maybe_mark_before(query, id), do: where(query, [_s, m], m.id < ^id)

  defp maybe_mark_after(query, nil), do: query
  defp maybe_mark_after(query, id), do: where(query, [_s, m], m.id > ^id)

  @doc """
  Follows a tag, which puts its posts in a home timeline.

  A relationship rather than a bookmark, because it changes what is delivered
  to somebody rather than what they can find later.
  """
  @spec follow_tag(Account.t() | integer(), Tag.t()) :: :ok
  def follow_tag(%Account{id: id}, tag), do: follow_tag(id, tag)

  def follow_tag(account_id, %Tag{} = tag) do
    do_follow_tag(account_id, tag)

    # Its recent posts, brought in now, so a followed tag has something under
    # it the moment somebody follows it.
    Abuuba.Timelines.merge_tag(account_id, tag)
  end

  defp do_follow_tag(account_id, %Tag{id: tag_id}) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "tag_follows",
      [%{account_id: account_id, tag_id: tag_id, inserted_at: now, updated_at: now}],
      on_conflict: :nothing,
      conflict_target: [:account_id, :tag_id]
    )

    :ok
  end

  @doc """
  Stops following one.
  """
  @spec unfollow_tag(Account.t() | integer(), Tag.t()) :: :ok
  def unfollow_tag(%Account{id: id}, tag), do: unfollow_tag(id, tag)

  def unfollow_tag(account_id, %Tag{id: tag_id} = tag) do
    from(f in "tag_follows", where: f.account_id == ^account_id and f.tag_id == ^tag_id)
    |> Repo.delete_all()

    # Anything still reachable through a follow stays: a post does not stop
    # being by somebody you follow because you stopped following its hashtag.
    Abuuba.Timelines.unmerge_tag(account_id, tag)
  end

  @doc """
  Whether somebody follows a tag.
  """
  @spec following_tag?(Account.t() | integer() | nil, Tag.t()) :: boolean()
  def following_tag?(nil, _tag), do: false
  def following_tag?(%Account{id: id}, tag), do: following_tag?(id, tag)

  def following_tag?(account_id, %Tag{id: tag_id}) do
    from(f in "tag_follows", where: f.account_id == ^account_id and f.tag_id == ^tag_id)
    |> Repo.exists?()
  end

  @doc """
  Which of the given tags somebody follows, as a set of tag ids.

  One question for a page of tags, where asking `following_tag?/2` per tag
  made a list of a hundred followed tags a hundred queries.
  """
  @spec followed_tag_ids(Account.t() | integer() | nil, [integer()]) :: MapSet.t()
  def followed_tag_ids(nil, _tag_ids), do: MapSet.new()
  def followed_tag_ids(%Account{id: id}, tag_ids), do: followed_tag_ids(id, tag_ids)
  def followed_tag_ids(_account_id, []), do: MapSet.new()

  def followed_tag_ids(account_id, tag_ids) do
    from(f in "tag_follows",
      where: f.account_id == ^account_id and f.tag_id in ^tag_ids,
      select: f.tag_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Which of `tag_ids` somebody has put on their own profile.

  The companion of `followed_tag_ids/2`, and batched for the same reason: this
  answers one field on every hashtag in a list.
  """
  @spec featured_tag_ids(Account.t() | integer() | nil, [integer()]) :: MapSet.t()
  def featured_tag_ids(nil, _tag_ids), do: MapSet.new()
  def featured_tag_ids(%Account{id: id}, tag_ids), do: featured_tag_ids(id, tag_ids)
  def featured_tag_ids(_account_id, []), do: MapSet.new()

  def featured_tag_ids(account_id, tag_ids) do
    from(f in FeaturedTag,
      where: f.account_id == ^account_id and f.tag_id in ^tag_ids,
      select: f.tag_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Which tags somebody follows.
  """
  @spec followed_tags(Account.t() | integer(), map()) :: [Tag.t()]
  def followed_tags(account, page \\ %{})
  def followed_tags(%Account{id: id}, page), do: followed_tags(id, page)

  def followed_tags(account_id, page) do
    Tag
    |> join(:inner, [t], f in "tag_follows", on: f.tag_id == t.id)
    |> where([_t, f], f.account_id == ^account_id)
    |> order_by([t], asc: t.name)
    |> limit(^Map.get(page, :limit, 100))
    |> Repo.all()
  end

  @doc """
  How many hashtags one profile may carry.

  Published in the instance document, so a client can show the limit rather
  than let somebody hit it. One number, read from here by both.
  """
  @spec featured_tags_max() :: pos_integer()
  def featured_tags_max, do: @featured_tags_max

  @doc """
  Tags somebody put on their own profile, with how much they have posted under
  each.

  Busiest first, so a profile leads with the tag the person actually writes
  about. The reference implementation leaves them in the order they were added,
  which puts whatever somebody tried once at the top of their profile forever.

  Two queries whatever the number of tags: the rows, then one grouped count
  across all of them. Asking per tag is four queries for a profile, on a page
  that is already asking for posts.
  """
  @spec featured_tags(Account.t() | integer()) :: [FeaturedTag.t()]
  def featured_tags(%Account{id: id}), do: featured_tags(id)

  def featured_tags(account_id) do
    records =
      FeaturedTag
      |> where([f], f.account_id == ^account_id)
      |> preload(:tag)
      |> Repo.all()

    stats = tag_stats(account_id, Enum.map(records, & &1.tag_id))

    records
    |> Enum.map(fn record ->
      %{count: count, last: last} = Map.get(stats, record.tag_id, %{count: 0, last: nil})

      %{record | statuses_count: count, last_status_at: last}
    end)
    |> Enum.sort_by(&{-&1.statuses_count, &1.tag.name})
  end

  @doc """
  Just the tags, for a caller that does not care how often they are used.

  One indexed join, deliberately not `featured_tags/1` with the counts thrown
  away: the two callers are a profile page render and a peer fetching the
  collection, and neither should pay for an aggregate it discards.
  """
  @spec featured_tag_names(Account.t() | integer()) :: [Tag.t()]
  def featured_tag_names(%Account{id: id}), do: featured_tag_names(id)

  def featured_tag_names(account_id) do
    Tag
    |> join(:inner, [t], f in FeaturedTag, on: f.tag_id == t.id)
    |> where([_t, f], f.account_id == ^account_id)
    |> order_by([t], asc: t.name)
    |> Repo.all()
  end

  @doc """
  One of somebody's featured tags by the id the API handed out, or `nil`.
  """
  @spec get_featured_tag(Account.t() | integer(), integer() | nil) :: FeaturedTag.t() | nil
  def get_featured_tag(%Account{id: id}, featured_id), do: get_featured_tag(id, featured_id)
  def get_featured_tag(_account_id, nil), do: nil

  def get_featured_tag(account_id, featured_id) do
    FeaturedTag
    |> where([f], f.id == ^featured_id and f.account_id == ^account_id)
    |> preload(:tag)
    |> Repo.one()
  end

  @doc """
  One account's featured row for a given tag, or `nil`.

  For a caller that has just featured something and wants the row the API hands
  back, without asking for the whole profile's worth again.
  """
  @spec get_featured_tag_for(Account.t() | integer(), Tag.t()) :: FeaturedTag.t() | nil
  def get_featured_tag_for(%Account{id: id}, tag), do: get_featured_tag_for(id, tag)

  def get_featured_tag_for(account_id, %Tag{id: tag_id}) do
    FeaturedTag
    |> where([f], f.account_id == ^account_id and f.tag_id == ^tag_id)
    |> preload(:tag)
    |> Repo.one()
    |> with_stats(account_id)
  end

  defp with_stats(nil, _account_id), do: nil

  defp with_stats(%FeaturedTag{} = featured, account_id) do
    %{count: count, last: last} =
      account_id
      |> tag_stats([featured.tag_id])
      |> Map.get(featured.tag_id, %{count: 0, last: nil})

    %{featured | statuses_count: count, last_status_at: last}
  end

  @doc """
  Tags somebody has been using lately and has not featured yet.

  What a client offers when somebody opens the "feature a tag" box. Only tags
  used more than once, because a tag used once is not what a person is about.
  """
  @spec featured_tag_suggestions(Account.t() | integer(), keyword()) :: [Tag.t()]
  def featured_tag_suggestions(account, opts \\ [])
  def featured_tag_suggestions(%Account{id: id}, opts), do: featured_tag_suggestions(id, opts)

  def featured_tag_suggestions(account_id, opts) do
    featured = from(f in FeaturedTag, where: f.account_id == ^account_id, select: f.tag_id)

    # Bounded to the last few hundred posts rather than to everything ever
    # written. This runs on every settings page load, and what somebody has
    # been writing about lately is the question anyway: a tag they used twice
    # in 2019 is not a suggestion.
    recent =
      from(s in Status,
        where: s.account_id == ^account_id and is_nil(s.deleted_at),
        order_by: [desc: s.id],
        limit: @suggestion_window,
        select: s.id
      )

    from(t in Tag,
      join: st in "statuses_tags",
      on: st.tag_id == t.id,
      where: st.status_id in subquery(recent),
      where: t.id not in subquery(featured),
      group_by: t.id,
      having: count(st.status_id) > 1,
      order_by: [desc: count(st.status_id)],
      limit: ^Keyword.get(opts, :limit, 10)
    )
    |> Repo.all()
  end

  @doc """
  Puts a tag on somebody's profile, by the word somebody typed.

  The tag is created if this server has never seen it: a person featuring a
  word is saying they intend to write under it, and refusing because nobody has
  used it yet refuses exactly the case where featuring it is most useful. A
  leading `#` and any capitals are somebody typing, not part of the name;
  `Tag.normalise/1` is where that is decided, for this and every other path.
  """
  @spec feature_tag_by_name(Account.t(), String.t()) ::
          {:ok, Tag.t()} | {:error, Ecto.Changeset.t() | :too_many}
  def feature_tag_by_name(%Account{} = account, name) do
    with {:ok, tag} <- upsert_tag(to_string(name)),
         :ok <- feature_tag(account, tag) do
      {:ok, tag}
    end
  end

  @doc """
  Takes one back off, by name. Silent about a tag nobody featured.
  """
  @spec unfeature_tag_by_name(Account.t(), String.t()) :: :ok
  def unfeature_tag_by_name(%Account{} = account, name) do
    case get_tag(to_string(name)) do
      nil -> :ok
      tag -> unfeature_tag(account, tag)
    end
  end

  @doc """
  Puts a tag on somebody's profile.

  `{:error, :too_many}` past the limit this server advertises. A client reads
  that limit out of the instance document and shows it; a server that took an
  eleventh anyway would be publishing a number it does not keep to.
  """
  @spec feature_tag(Account.t(), Tag.t()) :: :ok | {:error, :too_many}
  def feature_tag(%Account{id: account_id} = account, %Tag{id: tag_id} = tag) do
    now = DateTime.utc_now()

    if featured_tag_count(account_id) >= featured_tags_max() and
         not featured?(account_id, tag_id) do
      {:error, :too_many}
    else
      {added, _} =
        Repo.insert_all(
          FeaturedTag,
          [%{account_id: account_id, tag_id: tag_id, inserted_at: now, updated_at: now}],
          on_conflict: :nothing,
          conflict_target: [:account_id, :tag_id]
        )

      # Only when something actually changed. Peers cache a profile's
      # collections until told otherwise, and telling them about a tag that was
      # already there is a delivery to every follower for nothing.
      if added > 0, do: Outbox.tag_featured(account, tag)

      :ok
    end
  end

  defp featured_tag_count(account_id) do
    FeaturedTag |> where([f], f.account_id == ^account_id) |> Repo.aggregate(:count)
  end

  defp featured?(account_id, tag_id) do
    FeaturedTag
    |> where([f], f.account_id == ^account_id and f.tag_id == ^tag_id)
    |> Repo.exists?()
  end

  @doc """
  Takes it back off.
  """
  @spec unfeature_tag(Account.t(), Tag.t()) :: :ok
  def unfeature_tag(%Account{id: account_id} = account, %Tag{id: tag_id} = tag) do
    {removed, _} =
      from(f in FeaturedTag, where: f.account_id == ^account_id and f.tag_id == ^tag_id)
      |> Repo.delete_all()

    if removed > 0, do: Outbox.tag_unfeatured(account, tag)

    :ok
  end

  # Public and unlisted only. A featured tag's count is on a public profile, so
  # counting followers-only posts would publish how much somebody writes where
  # the reader cannot see, which is a number they never agreed to give away.
  defp tag_stats(_account_id, []), do: %{}

  defp tag_stats(account_id, tag_ids) do
    from(st in "statuses_tags",
      join: s in Status,
      on: s.id == st.status_id,
      where: st.tag_id in ^tag_ids and s.account_id == ^account_id,
      where: is_nil(s.deleted_at) and s.visibility in ^[:public, :unlisted],
      group_by: st.tag_id,
      select: {st.tag_id, %{count: count(st.status_id), last: max(s.inserted_at)}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Finds a tag by any spelling of its name, without creating one.
  """
  @spec get_tag(String.t() | nil) :: Tag.t() | nil
  def get_tag(nil), do: nil
  def get_tag(name) when is_binary(name), do: Repo.get_by(Tag, name: Tag.normalise(name))
  def get_tag(_name), do: nil

  @doc """
  Tags a page may list, newest first.

  Listable only: a moderator hiding a tag has to hide it everywhere it would be
  offered, and a discovery page is exactly where an unlisted one must not turn
  up.
  """
  @spec listable_tags(keyword()) :: [Tag.t()]
  def listable_tags(opts \\ []) do
    Tag
    |> where([t], t.listable)
    |> order_by([t], desc: t.id)
    |> limit(^Keyword.get(opts, :limit, 20))
    |> Repo.all()
  end

  @doc """
  Tags whose name starts with what somebody typed.
  """
  @spec search_tags(String.t() | nil, keyword()) :: [Tag.t()]
  def search_tags(query, opts \\ [])
  def search_tags(nil, _opts), do: []

  def search_tags(query, opts) do
    term = query |> to_string() |> String.trim() |> String.trim_leading("#") |> Tag.normalise()

    if term == "" do
      []
    else
      pattern = term |> String.replace(~r/([%_\\])/, "\\\\\\1") |> Kernel.<>("%")

      Tag
      |> where([t], t.listable and ilike(t.name, ^pattern))
      |> order_by([t], asc: fragment("length(?)", t.name), asc: t.name)
      |> limit(^Keyword.get(opts, :limit, 20))
      |> Repo.all()
    end
  end
end

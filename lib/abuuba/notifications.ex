defmodule Abuuba.Notifications do
  @moduledoc """
  Telling somebody what happened, and deciding what not to tell them.

  ## Two lists, decided on the way in

  A notification either goes into the main list or into the requests inbox, and
  which one is settled when it is written rather than when it is read. Deciding
  at read time would mean the same notification moving between lists as
  relationships change: somebody would accept a request, then see the same
  mention reappear as a request a week later because a follow lapsed.

  ## Who it is from, decided on the way out

  *Which* list is a write-time question; whether the reader wants to hear from
  this person at all is not. `decide/4` runs once, against the relationships as
  they stood that second, so blocking somebody afterwards left every favourite
  they had ever made sitting in the tab with the badge counting them --
  nothing here ever asked again.

  So `excluding_unwanted/2` is composed by every read: the list, the grouped
  list, one group, one notification, and all three counts. A badge that
  disagrees with the list under it is the same bug wearing a different number,
  and the counts are the half nobody remembers.

  ## Grouping

  Twenty people boosting one post is one thing that happened and a client shows
  it as one line. The key is on the row, so reading a grouped list is a plain
  query rather than grouping the whole table per request.

  ## The unread count stops at a thousand

  Nobody reads the difference between 1,200 and 4,000, every client renders
  both as "99+", and counting the whole table to produce a number nothing shows
  is work for its own sake.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Notifications.Notification
  alias Abuuba.Notifications.Policy
  alias Abuuba.Notifications.Request
  alias Abuuba.Pagination
  alias Abuuba.Relationships
  alias Abuuba.Relationships.Block
  alias Abuuba.Relationships.DomainBlock
  alias Abuuba.Relationships.Mute
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status
  alias Abuuba.Streaming
  alias Abuuba.Timelines.Marker
  alias Abuuba.WebPush.DeliveryWorker
  alias Ecto.Multi

  @unread_cap 1000

  # Notifications a person is the subject of rather than the audience for, and
  # which therefore carry their own account as the sender.
  #
  # A poll closing is one of them for its author: the sender named on it is the
  # poll's own account, and nobody did anything -- a clock ran out. Without it
  # here the author of a poll is the one person never told how it ended.
  @about_you ~w(annual_report poll)

  # A post boosted ten thousand times is one line in a client, and the client
  # needs a handful of faces for it rather than ten thousand account entities.
  # The count a group reports is the number of rows, not the number of faces.
  @group_cap 100

  @doc """
  The most an unread count will say.
  """
  @spec unread_cap() :: pos_integer()
  def unread_cap, do: @unread_cap

  @doc """
  Tells somebody about something, unless their policy says otherwise.

  Returns `{:ok, notification}` either way; the notification carries whether it
  was filtered. `{:ok, :dropped}` where the policy said to drop it, and
  `:ignored` where there is nobody to tell.
  """
  @spec notify(Account.t() | integer(), Account.t() | integer(), String.t(), keyword()) ::
          {:ok, Notification.t()} | {:ok, :dropped} | :ignored | {:error, term()}
  def notify(account, from_account, type, opts \\ [])

  def notify(%Account{id: id}, from_account, type, opts),
    do: notify(id, from_account, type, opts)

  def notify(account_id, %Account{id: id}, type, opts),
    do: notify(account_id, id, type, opts)

  # Nobody is told about their own actions. Somebody favouriting their own post
  # already knows.
  #
  # Except where the notification is about them rather than by them: a year in
  # review is the server telling somebody something, and it has no other sender
  # to name. Listed rather than allowed generally, so that the ordinary rule
  # still catches the ordinary mistake.
  def notify(account_id, account_id, type, opts) when type in @about_you,
    do: write(account_id, account_id, type, opts, false)

  def notify(account_id, account_id, _type, _opts), do: :ignored

  def notify(account_id, from_account_id, type, opts) do
    if local?(account_id) do
      filed(account_id, from_account_id, type, opts)
    else
      # Somebody on another server is told by their own, not by this one. The
      # guard is here rather than at each call site because the next call site
      # would forget it, and a row nobody can ever read is worse than none: it
      # counts towards a badge that is never shown.
      :ignored
    end
  end

  defp local?(account_id) do
    from(a in Account, where: a.id == ^account_id and is_nil(a.domain), select: 1)
    |> Repo.exists?()
  end

  defp filed(account_id, from_account_id, type, opts) do
    case decide(account_id, from_account_id, type, opts) do
      :drop ->
        {:ok, :dropped}

      decision ->
        write(account_id, from_account_id, type, opts, decision == :filter)
    end
  end

  defp write(account_id, from_account_id, type, opts, filtered?) do
    attrs = %{
      account_id: account_id,
      from_account_id: from_account_id,
      type: type,
      status_id: Keyword.get(opts, :status_id),
      # Passed in where the thing to group by is not the notification's own
      # post: twenty boosts of one post are one thing that happened, and each
      # notification names a different boost.
      group_key: Keyword.get(opts, :group_key),
      filtered: filtered?
    }

    %Notification{}
    |> Notification.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment,
         "(account_id, from_account_id, type, status_id) WHERE status_id IS NOT NULL"}
    )
    |> case do
      {:ok, %Notification{id: nil}} -> :ignored
      {:ok, notification} -> after_write(notification)
      error -> error
    end
  end

  defp after_write(%Notification{filtered: false} = notification) do
    Streaming.publish_notification(notification)
    DeliveryWorker.enqueue(notification)

    {:ok, notification}
  end

  defp after_write(%Notification{} = notification) do
    bump_request(notification)

    {:ok, notification}
  end

  @doc """
  Removes the notification about something that has been undone.

  There is no polymorphic activity column here, so a notification is named by
  the tuple that produced it: who was told, who by, and which of the things
  that can be undone it was. `:status_id` narrows it where the type has one --
  a favourite of this post rather than of every post.

  Undoing something has to take its notification with it, or the reader keeps
  being told about something that is no longer true: "X followed you" from
  somebody who is not following, and a card offering to follow them back.
  """
  @spec forget(integer(), integer(), String.t(), keyword()) :: :ok
  def forget(account_id, from_account_id, type, opts \\ []) do
    Notification
    |> where([n], n.account_id == ^account_id)
    |> where([n], n.from_account_id == ^from_account_id and n.type == ^type)
    |> narrow_to_status(Keyword.get(opts, :status_id))
    |> Repo.delete_all()

    :ok
  end

  defp narrow_to_status(query, nil), do: query
  defp narrow_to_status(query, status_id), do: where(query, [n], n.status_id == ^status_id)

  @doc """
  Removes every notification about one post.

  For a post being deleted, which takes the mentions, favourites and boosts
  people were told about with it. The foreign key would do this if the delete
  were a real one; it is a soft delete, so the row survives and the key never
  fires.
  """
  @spec forget_status(integer()) :: :ok
  def forget_status(status_id) do
    Notification |> where([n], n.status_id == ^status_id) |> Repo.delete_all()

    :ok
  end

  ## Policy

  @doc """
  Somebody's notification policy, defaulted where they have never set one.
  """
  @spec policy(Account.t() | integer()) :: Policy.t()
  def policy(%Account{id: id}), do: policy(id)

  def policy(account_id) do
    Repo.get_by(Policy, account_id: account_id) || %Policy{account_id: account_id}
  end

  @doc """
  Changes it.
  """
  @spec put_policy(Account.t() | integer(), map()) ::
          {:ok, Policy.t()} | {:error, Ecto.Changeset.t()}
  def put_policy(%Account{id: id}, attrs), do: put_policy(id, attrs)

  def put_policy(account_id, attrs) do
    account_id
    |> policy()
    |> Policy.changeset(Map.put(normalise(attrs), "account_id", account_id))
    |> Repo.insert_or_update()
  end

  defp normalise(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  # Which of the six axes this sender trips, and the strictest answer among
  # them. Strictest rather than first: somebody who is both a brand new account
  # and a bot has tripped two, and the person set both for a reason.
  defp decide(account_id, from_account_id, type, opts) do
    cond do
      # Whatever kind of notification it is. A policy decides how much of a
      # stranger somebody is; this is the reader having already said they do
      # not want to hear from this one, and it outranks the rest.
      Relationships.notifications_silenced?(account_id, from_account_id) -> :drop
      Notification.filterable?(type) -> by_policy(account_id, from_account_id, type, opts)
      true -> :accept
    end
  end

  defp by_policy(account_id, from_account_id, type, opts) do
    policy = policy(account_id)
    from = Repo.get(Account, from_account_id)
    follows = Relationships.between(account_id, from_account_id)

    [
      {:for_not_following, not follows.following},
      {:for_not_followers, not follows.followed_by},
      {:for_new_accounts, new_account?(from)},
      {:for_private_mentions, private_mention?(type, opts, follows, account_id, from_account_id)},
      {:for_limited_accounts, limited?(from)},
      {:for_bots, from != nil and from.bot}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(fn {axis, _tripped} -> Map.get(policy, axis) end)
    |> strictest()
  end

  defp strictest(decisions) do
    cond do
      "drop" in decisions -> :drop
      "filter" in decisions -> :filter
      true -> :accept
    end
  end

  # Thirty days, which is long enough that somebody who joined to talk to one
  # person is past it before they notice, and short enough to catch an account
  # made this morning to shout at somebody.
  defp new_account?(nil), do: false

  defp new_account?(%Account{inserted_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :day) < 30
  end

  defp limited?(nil), do: false
  defp limited?(%Account{silenced_at: at}), do: not is_nil(at)

  # Somebody you follow is somebody you agreed to hear from, so their direct
  # message goes to the main list like any other. Without this the axis caught
  # every private mention, including from the people its owner most wanted to
  # hear from, and put them in the requests inbox where nobody looks.
  #
  # The reference implementation has a third condition this does not: a direct
  # mention that answers something the recipient wrote up the same thread is
  # not filtered either, even from a stranger. That needs a walk up the
  # ancestors and is #242.
  defp private_mention?("mention", _opts, %{following: true}, _account_id, _from_id), do: false

  defp private_mention?("mention", opts, _follows, account_id, from_id) do
    case Keyword.get(opts, :status_id) do
      nil ->
        false

      id ->
        case Repo.get(Status, id) do
          %Status{visibility: :direct} = status ->
            not answers_recipient?(status, account_id, from_id)

          _not_direct ->
            false
        end
    end
  end

  defp private_mention?(_type, _opts, _follows, _account_id, _from_id), do: false

  # Whether this direct message answers something the recipient wrote to the
  # sender, up the same thread.
  #
  # A conversation the recipient started is not one they need protecting from:
  # filtering the answer to their own question means going to look in the
  # requests inbox for the reply they are waiting for, which is the opposite of
  # what the axis is for.
  #
  # The walk does not stop at the first post that is not the recipient's,
  # because a conversation with three people in it is still one they started.
  # It stops at a hundred, which is the reference implementation's limit and
  # is there so that a thread built by a bug cannot make this run for ever.
  defp answers_recipient?(%Status{in_reply_to_id: nil}, _account_id, _from_id), do: false

  defp answers_recipient?(%Status{in_reply_to_id: parent_id}, account_id, from_id) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE ancestors(id, in_reply_to_id, depth) AS (
          SELECT s.id, s.in_reply_to_id, 0
            FROM statuses s
           WHERE s.id = $1
          UNION ALL
          SELECT s.id, s.in_reply_to_id, a.depth + 1
            FROM statuses s
            JOIN ancestors a ON s.id = a.in_reply_to_id
           WHERE a.depth < 100
        )
        SELECT 1
          FROM ancestors a
          JOIN statuses s ON s.id = a.id
          JOIN mentions m ON m.status_id = s.id
         WHERE s.account_id = $2
           AND m.account_id = $3
           AND m.silent = false
         LIMIT 1
        """,
        [parent_id, account_id, from_id]
      )

    rows != []
  end

  ## Reading

  @doc """
  Somebody's notifications, newest first.

  Filtered ones are left out unless asked for: they are the requests inbox, and
  a main list that carried them would defeat the point of having one.
  """
  @spec list(Account.t() | integer(), map()) :: [Notification.t()]
  def list(account, page \\ %{})
  def list(%Account{id: id}, page), do: list(id, page)

  def list(account_id, page) do
    from(n in Notification, as: :notification)
    |> where([n], n.account_id == ^account_id)
    |> excluding_unwanted(account_id)
    |> filter_state(page)
    |> filter_sender(page)
    |> filter_types(page)
    |> paginate(page)
  end

  # Two shapes, because the four rules are not alike.
  #
  # Blocks and mutes are the reader's own rows, so "everybody I will not hear
  # from" is a set bounded by how many people *they* have shut out -- a handful
  # for almost everyone. Postgres hashes it once per query and probes it per
  # row, which beats three correlated lookups per row on a query that runs on
  # every signed-in page render.
  #
  # `NOT IN` is safe here only because both columns are `NOT NULL`: a single
  # NULL in the set would make the whole predicate answer NULL and hide every
  # notification. That is checked by the schema, not by luck.
  defp silenced_ids(account_id) do
    now = DateTime.utc_now()

    blocked = from(b in Block, where: b.account_id == ^account_id, select: b.target_account_id)

    blocking = from(b in Block, where: b.target_account_id == ^account_id, select: b.account_id)

    # `hide_notifications` is why this is not the timeline's mute rule. A mute
    # that left notifications on is somebody saying "off my timeline, still
    # tell me", and the write side honours that -- so read time has to as
    # well, or the flag means nothing the moment anybody reloads.
    muted =
      from(m in Mute,
        where:
          m.account_id == ^account_id and m.hide_notifications and
            (is_nil(m.expires_at) or m.expires_at > ^now),
        select: m.target_account_id
      )

    blocked |> union_all(^blocking) |> union_all(^muted)
  end

  # The domain rule is the exception, and stays correlated. Written as a set it
  # would be every account on the blocked server: one domain block against a
  # large instance turned this into a sequential scan of `accounts` per
  # notification on the benchmark database -- 145 million buffer hits for a
  # badge. Asked per row it is one primary-key probe.
  defmacrop on_a_blocked_server(account_id, subject) do
    quote do
      from(a in Account,
        join: d in DomainBlock,
        on: d.domain == a.domain and d.account_id == ^unquote(account_id),
        where: a.id == unquote(subject),
        select: 1
      )
    end
  end

  @doc """
  Drops what this reader has since said they do not want.

  One rule asked of everybody a notification implicates: the sender, the
  author of the post it points at, and the author of whatever that post is
  carrying if it is a boost. That last one is the half the write side never
  had -- it asked about the sender and stopped, so a mention inside somebody
  else's boost of a blocked account arrived with the blocked account's words
  in it.

  The rule is `Relationships.notifications_silenced?/2`'s, not its call: that
  one answers about a pair in three round trips and cannot compose into a
  query. Same four questions, `hide_notifications` included, plus a block in
  either direction rather than only the reader's own.

  A deleted post is dropped on the way past, because a notification pointing
  at one points at nothing a reader can open. The undo paths take most of
  those away as they happen; this is the backstop for a moderator's removal or
  a path nobody has written yet.

  Correlated `EXISTS` rather than `NOT IN` over a set of ids: one domain block
  against a large server makes that set every account on it, and this runs on
  every page a signed-in reader loads. Needs the `:notification` binding.
  """
  @spec excluding_unwanted(Ecto.Query.t(), Account.t() | integer() | nil) :: Ecto.Query.t()
  def excluding_unwanted(query, nil), do: query

  def excluding_unwanted(query, %Account{id: id}), do: excluding_unwanted(query, id)

  def excluding_unwanted(query, account_id) do
    silenced = silenced_ids(account_id)

    query
    |> where([n], n.from_account_id not in subquery(silenced))
    |> where(
      [n],
      not exists(on_a_blocked_server(account_id, parent_as(:notification).from_account_id))
    )
    |> where([n], is_nil(n.status_id) or exists(wanted_post(account_id, silenced)))
  end

  # The post's author, and the author of what it repeats if it is a boost. On
  # every type this server writes the author is the sender or the reader, so
  # the sender clauses have answered already -- but a notification is a row
  # anything can write, and an invariant nothing enforces is not a check.
  #
  # A block is about the person whose words these are, not about who passed
  # them along, which is why the carried author is asked separately.
  defp wanted_post(account_id, silenced) do
    from(s in Status,
      as: :post,
      where: s.id == parent_as(:notification).status_id and is_nil(s.deleted_at),
      where: s.account_id not in subquery(silenced),
      where: not exists(on_a_blocked_server(account_id, parent_as(:post).account_id)),
      where: is_nil(s.reblog_of_id) or not exists(silenced_carried_author(account_id, silenced)),
      select: 1
    )
  end

  defp silenced_carried_author(account_id, silenced) do
    from(carried in Status,
      as: :carried,
      where: carried.id == parent_as(:post).reblog_of_id,
      where:
        carried.account_id in subquery(silenced) or
          exists(on_a_blocked_server(account_id, parent_as(:carried).account_id)),
      select: 1
    )
  end

  # Which of the two lists this is: the ordinary one, the waiting list, or
  # both.
  #
  # Naming a sender drops the restriction entirely, which is the reference's
  # behaviour and worth keeping: somebody looking up one account has already
  # decided to look at them, and hiding half the answer behind the requests
  # inbox would be a strange thing to do to a direct question.
  defp filter_state(query, page) do
    cond do
      Map.get(page, :from_account_id) -> query
      Map.get(page, :include_filtered, false) -> query
      true -> where(query, [n], n.filtered == ^Map.get(page, :filtered, false))
    end
  end

  defp filter_sender(query, page) do
    case Map.get(page, :from_account_id) do
      nil -> query
      id -> where(query, [n], n.from_account_id == ^id)
    end
  end

  @doc """
  The same, one row per group rather than one per event.

  The newest of each group represents it, because that is what a client shows
  and what it sorts by.
  """
  @spec grouped(Account.t() | integer(), map()) :: [
          %{key: String.t(), notifications: [Notification.t()]}
        ]
  def grouped(account, page \\ %{}) do
    account
    |> list(page)
    |> Enum.group_by(& &1.group_key)
    |> Enum.map(fn {key, notifications} ->
      %{key: key, notifications: Enum.sort_by(notifications, & &1.id, :desc)}
    end)
    |> Enum.sort_by(&hd(&1.notifications).id, :desc)
  end

  @doc """
  Everything in one group.
  """
  @spec group(Account.t() | integer(), String.t(), keyword()) :: [Notification.t()]
  def group(account, key, opts \\ [])
  def group(%Account{id: id}, key, opts), do: group(id, key, opts)

  def group(account_id, key, opts) do
    from(n in Notification, as: :notification)
    |> where([n], n.account_id == ^account_id and n.group_key == ^key)
    |> excluding_unwanted(account_id)
    |> order_by([n], desc: n.id)
    |> limit(^Keyword.get(opts, :limit, @group_cap))
    |> Repo.all()
  end

  @doc """
  One notification, if it is this account's and they still want it.
  """
  @spec get(Account.t() | integer(), integer() | nil) :: Notification.t() | nil
  def get(%Account{id: id}, notification_id), do: get(id, notification_id)
  def get(_account_id, nil), do: nil

  def get(account_id, notification_id) do
    from(n in Notification, as: :notification)
    |> where([n], n.id == ^notification_id and n.account_id == ^account_id)
    |> excluding_unwanted(account_id)
    |> Repo.one()
  end

  @doc """
  How many are newer than where somebody had read up to, capped.
  """
  @spec unread_count(Account.t() | integer(), integer() | nil) :: non_neg_integer()
  def unread_count(account, since_id \\ nil)
  def unread_count(%Account{id: id}, since_id), do: unread_count(id, since_id)

  def unread_count(account_id, since_id) do
    account_id
    |> unread_scope()
    |> after_marker(account_id)
    |> newer_than(since_id)
    |> count_capped()
  end

  @doc """
  How many unread groups there are, rather than how many rows.

  What a client using the grouped API puts on its tab. Forty people
  favouriting one post is one thing that happened, and counting it as forty is
  a badge that says the reader has missed forty things they have not.
  """
  @spec unread_group_count(Account.t() | integer(), integer() | nil) :: non_neg_integer()
  def unread_group_count(account, since_id \\ nil)
  def unread_group_count(%Account{id: id}, since_id), do: unread_group_count(id, since_id)

  def unread_group_count(account_id, since_id) do
    account_id
    |> unread_scope()
    |> after_marker(account_id)
    |> newer_than(since_id)
    |> select([n], n.group_key)
    |> distinct(true)
    |> limit(@unread_cap)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  @doc """
  The unread count for the navigation badge, marker included.

  `unread_count/2` with the marker looked up for the caller. Two round trips
  rather than one, deliberately: see `after_marker/2` for what the second one
  buys, which is most of the query.
  """
  @spec unread_badge(integer()) :: non_neg_integer()
  def unread_badge(account_id) do
    account_id |> unread_scope() |> after_marker(account_id) |> count_capped()
  end

  # What "unread" means: everything past where the reader said they had got to.
  # Without it the count is "everything ever", so a client's badge shows a
  # number that never comes down however much somebody reads.
  # Two round trips, and worth it. Where the bound sits decides what the scan
  # may skip: as a left join the filter is applied *above* the notifications
  # scan, so every rule `excluding_unwanted/2` asks was asked of the reader's
  # whole history to answer a question about the last forty. Read first, the
  # bound is a literal, `notifications(account_id, filtered, id)` becomes a
  # range, and the rules are asked forty times.
  #
  # Measured on a database of 3,000 notifications with forty unread: 16,862
  # buffers and 8.9 ms as a join, 399 and 1.1 ms this way. A scalar subquery
  # is the shape that looks right and is not -- the planner cannot range-scan
  # on a bound it does not know yet, and it measured 1,619 buffers and 18.7 ms,
  # slower than the join it replaced.
  defp after_marker(query, account_id) do
    where(query, [n], n.id > ^read_up_to(account_id))
  end

  defp read_up_to(account_id) do
    from(m in Marker,
      where: m.account_id == ^account_id and m.timeline == "notifications",
      select: m.last_read_id
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp unread_scope(account_id) do
    from(n in Notification, as: :notification)
    |> where([n], n.account_id == ^account_id and not n.filtered)
    |> excluding_unwanted(account_id)
  end

  # The cap lives in the query, so counting stops at a thousand rather than
  # walking somebody's whole history to report a number every client shows as
  # "99+" anyway.
  defp count_capped(query) do
    query
    |> limit(@unread_cap)
    |> select([n], n.id)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  @doc """
  Forgets one.
  """
  @spec dismiss(Account.t() | integer(), integer()) :: :ok
  def dismiss(%Account{id: id}, notification_id), do: dismiss(id, notification_id)

  def dismiss(account_id, notification_id) do
    Notification
    |> where([n], n.account_id == ^account_id and n.id == ^notification_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Forgets everything in one group.

  One statement rather than one per row: a popular post's group holds every
  boost it got, and dismissing it should not be a hundred round trips.
  """
  @spec dismiss_group(Account.t() | integer(), String.t()) :: :ok
  def dismiss_group(%Account{id: id}, key), do: dismiss_group(id, key)

  def dismiss_group(account_id, key) do
    Notification
    |> where([n], n.account_id == ^account_id and n.group_key == ^key)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Forgets all of them.
  """
  @spec clear(Account.t() | integer()) :: :ok
  def clear(%Account{id: id}), do: clear(id)

  def clear(account_id) do
    Notification |> where([n], n.account_id == ^account_id) |> Repo.delete_all()

    :ok
  end

  ## The requests inbox

  @doc """
  Who has been filtered, and how much of them there is.
  """
  @spec requests(Account.t() | integer(), map()) :: [Request.t()]
  def requests(account, page \\ %{})
  def requests(%Account{id: id}, page), do: requests(id, page)

  def requests(account_id, page) do
    # The same sender question the list asks. A request is a notification the
    # policy set aside rather than a different kind of thing, so blocking
    # somebody afterwards has to empty it here too -- otherwise the inbox is
    # where they keep their name and their count.
    from(r in Request, as: :request)
    |> where([r], r.account_id == ^account_id and is_nil(r.dismissed_at))
    |> where([r], r.from_account_id not in subquery(silenced_ids(account_id)))
    |> where(
      [r],
      not exists(on_a_blocked_server(account_id, parent_as(:request).from_account_id))
    )
    |> order_by([r], desc: r.id)
    |> limit(^Map.get(page, :limit, 40))
    |> Repo.all()
  end

  @doc """
  One request from somebody's inbox, by the id the API handed out, or `nil`.
  """
  @spec get_request(Account.t() | integer(), integer() | nil) :: Request.t() | nil
  def get_request(%Account{id: id}, request_id), do: get_request(id, request_id)
  def get_request(_account_id, nil), do: nil

  def get_request(account_id, request_id) do
    # Not one that has been put away. The list stops showing a dismissed
    # request, and an id that still answers would be the same request coming
    # back for a client that kept it.
    Request
    |> where([r], r.id == ^request_id and r.account_id == ^account_id)
    |> where([r], is_nil(r.dismissed_at))
    |> Repo.one()
  end

  @doc """
  Accepts somebody: their filtered notifications join the main list and future
  ones are not filtered.

  Both halves in one transaction. Moving the old ones without recording the
  decision would file the next one under requests again, and recording it
  without moving them would leave the person's mentions in a folder they just
  said they did not want.
  """
  @spec accept_request(Account.t() | integer(), integer()) :: :ok | {:error, :not_found}
  def accept_request(%Account{id: id}, from_account_id),
    do: accept_request(id, from_account_id)

  def accept_request(account_id, from_account_id) do
    case Repo.get_by(Request, account_id: account_id, from_account_id: from_account_id) do
      nil ->
        {:error, :not_found}

      request ->
        Multi.new()
        |> Multi.update_all(
          :unfilter,
          from(n in Notification,
            where: n.account_id == ^account_id and n.from_account_id == ^from_account_id
          ),
          set: [filtered: false]
        )
        |> Multi.delete(:request, request)
        |> Repo.transaction()

        :ok
    end
  end

  @doc """
  Dismisses somebody without accepting them: the request goes away and their
  notifications stay filtered.
  """
  @spec dismiss_request(Account.t() | integer(), integer()) :: :ok
  def dismiss_request(%Account{id: id}, from_account_id),
    do: dismiss_request(id, from_account_id)

  def dismiss_request(account_id, from_account_id) do
    Request
    |> where([r], r.account_id == ^account_id and r.from_account_id == ^from_account_id)
    |> Repo.update_all(set: [dismissed_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])

    :ok
  end

  defp bump_request(%Notification{} = notification) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Request,
      [
        %{
          account_id: notification.account_id,
          from_account_id: notification.from_account_id,
          notifications_count: 1,
          last_status_id: notification.status_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      conflict_target: [:account_id, :from_account_id],
      on_conflict:
        from(r in Request,
          update: [
            inc: [notifications_count: 1],
            set: [
              last_status_id: ^notification.status_id,
              dismissed_at: nil,
              updated_at: ^now
            ]
          ]
        )
    )
  end

  ## Query pieces

  defp filter_types(query, page) do
    query
    |> include_types(Map.get(page, :types, []))
    |> exclude_types(Map.get(page, :exclude_types, []))
  end

  defp include_types(query, []), do: query
  defp include_types(query, types), do: where(query, [n], n.type in ^types)

  defp exclude_types(query, []), do: query
  defp exclude_types(query, types), do: where(query, [n], n.type not in ^types)

  defp paginate(query, page) do
    query
    |> older_than(Map.get(page, :max_id))
    |> newer_than(Map.get(page, :min_id) || Map.get(page, :since_id))
    |> order_by([n], [{^Pagination.direction(page), n.id}])
    |> limit(^Map.get(page, :limit, 40))
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  defp older_than(query, nil), do: query
  defp older_than(query, id), do: where(query, [n], n.id < ^id)

  defp newer_than(query, nil), do: query
  defp newer_than(query, id), do: where(query, [n], n.id > ^id)
end

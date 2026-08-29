defmodule Abuuba.Importer.Graph do
  @moduledoc """
  Who follows whom, and everything each person set for themselves.

  The follow graph is the part of a takeover nobody can rebuild. A post can be
  fetched again from the server that wrote it; a follow cannot be recovered
  from anywhere, because the only two records of it are the two servers that
  hold it, and one of those is the one being replaced. Losing it is asking
  every follower on the network to find you again.

  So follows come across with their URIs, which is what makes an inbound Undo
  from a peer match the row it is undoing, and with the three things that hang
  off them: whether boosts are shown, whether posts notify, and which languages
  were asked for.

  ## The rest is somebody's own settings

  Blocks, mutes, domain blocks, lists, filters, read markers, scheduled posts,
  notification policies and requests, private notes about other people. None of
  it is dramatic and all of it is noticed the moment it is gone: a block that
  did not come across is somebody seeing an account they blocked years ago.

  ## References follow the same rule as the content step

  A row pointing at a status the import did not copy is dropped or emptied
  rather than written, because the alternative is a foreign key violation that
  takes a whole batch with it.
  """

  @behaviour Abuuba.Importer.Step

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Collections.Collection
  alias Abuuba.Collections.Item, as: CollectionItem
  alias Abuuba.EmailSubscriptions.Subscription
  alias Abuuba.Federation.FollowerSync
  alias Abuuba.Filters.Filter
  alias Abuuba.Filters.Keyword, as: FilterKeyword
  alias Abuuba.Importer.Batch
  alias Abuuba.Importer.Source
  alias Abuuba.Lists.List, as: UserList
  alias Abuuba.Moderation.Severance
  alias Abuuba.Moderation.SeveranceEvent
  alias Abuuba.Notifications.Notification
  alias Abuuba.Notifications.Policy
  alias Abuuba.Notifications.Request
  alias Abuuba.Relationships.Block
  alias Abuuba.Relationships.DomainBlock
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.FollowRequest
  alias Abuuba.Relationships.Mute
  alias Abuuba.Relationships.Note
  alias Abuuba.Repo
  alias Abuuba.Statuses.ConversationMute
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Timelines.Marker

  @impl Abuuba.Importer.Step
  @spec run(keyword()) :: :ok | {:error, {atom(), term()}}
  def run(opts), do: Batch.run_parts(opts, parts())

  defp parts do
    [
      {:follows, &copy_follows/2},
      {:follow_requests, &copy_follow_requests/2},
      {:blocks, &copy_blocks/2},
      {:mutes, &copy_mutes/2},
      {:domain_blocks, &copy_domain_blocks/2},
      {:lists, &copy_lists/2},
      {:collections, &copy_collections/2},
      {:collection_items, &copy_collection_items/2},
      {:email_subscriptions, &copy_email_subscriptions/2},
      {:severance_events, &copy_severance_events/2},
      {:severed_relationships, &copy_severed/2},
      {:list_accounts, &copy_list_accounts/2},
      {:filters, &copy_filters/2},
      {:filter_keywords, &copy_filter_keywords/2},
      {:filter_statuses, &copy_filter_statuses/2},
      {:markers, &copy_markers/2},
      {:scheduled_statuses, &copy_scheduled/2},
      {:notification_policies, &copy_policies/2},
      {:notification_requests, &copy_requests/2},
      {:notifications, &copy_notifications/2},
      {:account_notes, &copy_notes/2},
      {:tag_follows, &copy_tag_follows/2},
      {:conversation_mutes, &copy_conversation_mutes/2}
    ]
  end

  @doc """
  Checks the follow graph against the source's own count of it.

  Followers are what the fediverse can see from outside, so a difference here
  is a difference other servers will notice before the admin does.
  """
  @impl Abuuba.Importer.Step
  @spec verify(keyword()) :: [Abuuba.Importer.Step.verification()]
  def verify(opts) do
    [digests(opts)]
  end

  # FEP-8fcf: each peer keeps a digest of the followers it believes this server
  # has for one of its accounts, and compares it with the one this server
  # publishes. It is an XOR of per-follower hashes, so either side can compute
  # it without sending a list — which is exactly what makes it checkable here.
  #
  # Computed per local account and peer domain, from the source's rows and from
  # ours. A pair that differs is a set of followers the import did not carry
  # across whole, and that peer will say so the next time it asks.
  defp digests(opts) do
    sql = "SELECT id FROM #{table(opts, "accounts")} WHERE domain IS NULL"

    {checked, failures} =
      Batch.scan(opts, sql, fn accounts ->
        ids = Enum.map(accounts, & &1["id"])

        compare(source_digests(opts, ids), local_digests(ids))
      end)

    %{name: "follower digests", checked: checked, failures: failures}
  end

  defp compare(source, here) do
    source
    |> Map.keys()
    |> Enum.concat(Map.keys(here))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(source, &1) == Map.get(here, &1)))
    |> Enum.map(fn {account_id, domain} ->
      %{
        id: account_id,
        domain: domain,
        was: source[{account_id, domain}],
        now: here[{account_id, domain}]
      }
    end)
  end

  defp source_digests(opts, ids) do
    # The follower's own actor URI is what goes into the digest, and the domain
    # it is grouped by is the one that will ask.
    sql = """
    SELECT f.target_account_id AS account_id, a.domain AS domain, a.uri AS uri
    FROM #{table(opts, "follows")} f
    JOIN #{table(opts, "accounts")} a ON a.id = f.account_id
    WHERE f.target_account_id = ANY($1) AND a.domain IS NOT NULL AND a.uri IS NOT NULL
    """

    case Source.rows(opts, sql, [ids]) do
      {:ok, rows} -> fold(Enum.map(rows, &{&1["account_id"], &1["domain"], &1["uri"]}))
      _error -> %{}
    end
  end

  defp local_digests(ids) do
    Follow
    |> join(:inner, [f], a in Account, on: a.id == f.account_id)
    |> where([f, a], f.target_account_id in ^ids and not is_nil(a.domain) and not is_nil(a.uri))
    |> select([f, a], {f.target_account_id, a.domain, a.uri})
    |> Repo.all()
    |> fold()
  end

  # Through the same function the server publishes with, so the check cannot
  # pass against a digest nobody would ever be sent.
  defp fold(rows) do
    rows
    |> Enum.group_by(fn {id, domain, _uri} -> {id, String.downcase(domain)} end, &elem(&1, 2))
    |> Map.new(fn {key, uris} -> {key, FollowerSync.digest(uris)} end)
  end

  ## Relationships

  defp copy_follows(opts, name) do
    copy(opts, name, Follow, "SELECT * FROM #{table(opts, "follows")}", &relationship/1)
  end

  defp copy_follow_requests(opts, name) do
    sql = "SELECT * FROM #{table(opts, "follow_requests")}"

    copy(opts, name, FollowRequest, sql, &relationship/1)
  end

  defp relationship(row) do
    %{
      id: row["id"],
      account_id: row["account_id"],
      target_account_id: row["target_account_id"],
      show_reblogs: row["show_reblogs"] != false,
      notify: row["notify"] == true,
      languages: row["languages"],
      # What an inbound Undo names. Without it a peer's unfollow arrives and
      # matches nothing.
      uri: presence(row["uri"]),
      inserted_at: at(row["created_at"]),
      updated_at: at(row["updated_at"])
    }
  end

  defp copy_blocks(opts, name) do
    copy(opts, name, Block, "SELECT * FROM #{table(opts, "blocks")}", fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        target_account_id: row["target_account_id"],
        uri: presence(row["uri"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_mutes(opts, name) do
    copy(opts, name, Mute, "SELECT * FROM #{table(opts, "mutes")}", fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        target_account_id: row["target_account_id"],
        hide_notifications: row["hide_notifications"] != false,
        expires_at: at(row["expires_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_domain_blocks(opts, name) do
    sql = """
    SELECT * FROM #{table(opts, "account_domain_blocks")}
    WHERE account_id IS NOT NULL AND domain IS NOT NULL
    """

    copy(opts, name, DomainBlock, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        domain: row["domain"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  ## Lists and filters

  # Spelled out rather than read off abuuba's own list by position: the two
  # happen to agree on the order today, and a silent mis-map would put somebody
  # back on a list they had left.
  @item_states %{0 => "pending", 1 => "accepted", 2 => "rejected", 3 => "revoked"}

  @severance_types %{0 => "domain_block", 1 => "user_domain_block", 2 => "account_suspension"}

  # Not a position in abuuba's own list, which has these two the other way round:
  # `passive` is 0 there and second here. Read as a position it would tell
  # somebody they had lost people they followed when what they lost was
  # followers.
  @severance_directions %{0 => "passive", 1 => "active"}

  # A collection is a list of people its author put together by hand, and there
  # is nowhere to recover one from. The two projects model it the same way; the
  # source keeps a rendered `description_html` and a `original_number_of_items`
  # that abuuba derives instead, so those are the only columns left behind.
  defp copy_collections(opts, name) do
    copy(opts, name, Collection, "SELECT * FROM #{table(opts, "collections")}", fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        name: row["name"] || "",
        description: row["description"] || "",
        sensitive: row["sensitive"] == true,
        discoverable: row["discoverable"] == true,
        local: row["local"] == true,
        language: row["language"],
        item_count: row["item_count"] || 0,
        tag_id: row["tag_id"],
        uri: row["uri"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # The source numbers the states and abuuba names them, in the same order. An
  # item whose account did not come across is left rather than written: the
  # column is nullable there and required here, and a row naming nobody is not
  # a membership.
  defp copy_collection_items(opts, name) do
    sql = "SELECT * FROM #{table(opts, "collection_items")}"

    copy(opts, name, CollectionItem, sql, fn row ->
      if row["account_id"] do
        %{
          id: row["id"],
          collection_id: row["collection_id"],
          account_id: row["account_id"],
          position: row["position"] || 1,
          state: item_state(row["state"]),
          inserted_at: at(row["created_at"]),
          updated_at: at(row["updated_at"])
        }
      end
    end)
  end

  defp item_state(number), do: Map.get(@item_states, number, "pending")

  # The token comes across with the row. It is what a pending confirmation link
  # already in somebody's inbox points at, and reissuing one would mean asking
  # again for a decision they have already made.
  defp copy_email_subscriptions(opts, name) do
    sql = "SELECT * FROM #{table(opts, "email_subscriptions")}"

    copy(opts, name, Subscription, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        email: row["email"],
        locale: row["locale"] || "en",
        token: row["confirmation_token"],
        confirmed_at: at(row["confirmed_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # What a domain block took from somebody. The follows are gone either way;
  # this is the record that tells them which block took them, and without it
  # the follower count simply dropped one day for no stated reason.
  defp copy_severance_events(opts, name) do
    sql = "SELECT * FROM #{table(opts, "relationship_severance_events")}"

    copy(opts, name, SeveranceEvent, sql, fn row ->
      %{
        id: row["id"],
        type: Map.get(@severance_types, row["type"], "domain_block"),
        target_name: row["target_name"] || "",
        purged: row["purged"] == true,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_severed(opts, name) do
    sql = "SELECT * FROM #{table(opts, "severed_relationships")}"

    copy(opts, name, Severance, sql, fn row ->
      %{
        id: row["id"],
        relationship_severance_event_id: row["relationship_severance_event_id"],
        local_account_id: row["local_account_id"],
        remote_account_id: row["remote_account_id"],
        direction: Map.get(@severance_directions, row["direction"], "passive"),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_lists(opts, name) do
    copy(opts, name, UserList, "SELECT * FROM #{table(opts, "lists")}", fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        title: row["title"] || "",
        replies_policy: replies_policy(row["replies_policy"]),
        exclusive: row["exclusive"] == true,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # No timestamps on the source's rows, so the list's own creation time stands
  # in: a membership cannot predate the list it is in.
  defp copy_list_accounts(opts, name) do
    sql = """
    SELECT la.id, la.list_id, la.account_id, l.created_at AS created_at
    FROM #{table(opts, "list_accounts")} la
    JOIN #{table(opts, "lists")} l ON l.id = la.list_id
    """

    copy(opts, name, "list_accounts", sql, fn row ->
      %{
        list_id: row["list_id"],
        account_id: row["account_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["created_at"])
      }
    end)
  end

  # The source keeps a phrase on the filter itself as well as its keywords;
  # abuuba keeps the title there and every phrase as a keyword, which is what the
  # v2 filter API describes. The phrase becomes the title so nothing a person
  # typed is lost.
  defp copy_filters(opts, name) do
    sql = "SELECT * FROM #{table(opts, "custom_filters")} WHERE account_id IS NOT NULL"

    copy(opts, name, Filter, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        title: row["phrase"] || "",
        context: row["context"] || [],
        filter_action: filter_action(row["action"]),
        expires_at: at(row["expires_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_filter_keywords(opts, name) do
    sql = """
    SELECT k.* FROM #{table(opts, "custom_filter_keywords")} k
    JOIN #{table(opts, "custom_filters")} f ON f.id = k.custom_filter_id
    WHERE f.account_id IS NOT NULL
    """

    copy(opts, name, FilterKeyword, sql, fn row ->
      %{
        id: row["id"],
        filter_id: row["custom_filter_id"],
        keyword: row["keyword"] || "",
        whole_word: row["whole_word"] != false,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_filter_statuses(opts, name) do
    sql = """
    SELECT fs.* FROM #{table(opts, "custom_filter_statuses")} fs
    JOIN #{table(opts, "custom_filters")} f ON f.id = fs.custom_filter_id
    JOIN #{table(opts, "statuses")} s ON s.id = fs.status_id AND s.deleted_at IS NULL
    WHERE f.account_id IS NOT NULL
    """

    copy(opts, name, "filter_statuses", sql, fn row ->
      %{
        id: row["id"],
        filter_id: row["custom_filter_id"],
        status_id: row["status_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  ## Reading state

  # Hung off the user over there and off the account here, so the two are
  # joined rather than copied. The id it points at is a status id and is left
  # alone even where that status is gone: a marker is a position in a timeline,
  # not a reference to a row, and moving it would mark things unread that
  # somebody has read.
  defp copy_markers(opts, name) do
    sql = """
    SELECT m.id, m.timeline, m.last_read_id, m.lock_version, m.created_at, m.updated_at,
           u.account_id AS account_id
    FROM #{table(opts, "markers")} m
    JOIN #{table(opts, "users")} u ON u.id = m.user_id
    """

    copy(opts, name, Marker, sql, fn row ->
      %{
        account_id: row["account_id"],
        timeline: row["timeline"],
        last_read_id: row["last_read_id"],
        version: row["lock_version"] || 0,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_scheduled(opts, name) do
    sql = """
    SELECT * FROM #{table(opts, "scheduled_statuses")}
    WHERE account_id IS NOT NULL AND scheduled_at IS NOT NULL
    """

    copy(opts, name, ScheduledStatus, sql, fn row ->
      params = row["params"] || %{}

      %{
        id: row["id"],
        account_id: row["account_id"],
        scheduled_at: at(row["scheduled_at"]),
        params: params,
        # Lifted out of the params, where the source keeps them, because this
        # side reads them as a column when the post is finally made.
        media_attachment_ids: media_ids(params),
        inserted_at: at(row["scheduled_at"]),
        updated_at: at(row["scheduled_at"])
      }
    end)
  end

  defp media_ids(%{"media_ids" => ids}) when is_list(ids) do
    Enum.flat_map(ids, fn id ->
      case Integer.parse(to_string(id)) do
        {number, ""} -> [number]
        _not_a_number -> []
      end
    end)
  end

  defp media_ids(_none), do: []

  ## Notifications

  defp copy_policies(opts, name) do
    sql = "SELECT * FROM #{table(opts, "notification_policies")}"

    copy(opts, name, Policy, sql, fn row ->
      %{
        account_id: row["account_id"],
        for_not_following: filter_setting(row["for_not_following"]),
        for_not_followers: filter_setting(row["for_not_followers"]),
        for_new_accounts: filter_setting(row["for_new_accounts"]),
        for_private_mentions: filter_setting(row["for_private_mentions"]),
        for_limited_accounts: filter_setting(row["for_limited_accounts"]),
        for_bots: filter_setting(row["for_bots"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_requests(opts, name) do
    sql = """
    SELECT r.*, last.id AS last_status_id
    FROM #{table(opts, "notification_requests")} r
    LEFT JOIN #{table(opts, "statuses")} last
      ON last.id = r.last_status_id AND last.deleted_at IS NULL
    """

    copy(opts, name, Request, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        from_account_id: row["from_account_id"],
        last_status_id: row["last_status_id"],
        notifications_count: row["notifications_count"] || 0,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # The source hangs a notification off whatever caused it, through a
  # polymorphic pair of columns; abuuba keeps the status directly, because a
  # status is what every notification that has one points at. The join is
  # written out per type rather than guessed, and a notification whose cause is
  # gone comes across without one rather than not at all: "somebody followed
  # you" is still true.
  defp copy_notifications(opts, name) do
    sql = """
    SELECT n.id, n.account_id, n.from_account_id, n.type, n.filtered, n.group_key,
           n.created_at, n.updated_at,
           coalesce(direct.id, mentioned.id, favourited.id, polled.id) AS status_id
    FROM #{table(opts, "notifications")} n
    LEFT JOIN #{table(opts, "statuses")} direct
      ON n.activity_type = 'Status' AND direct.id = n.activity_id AND direct.deleted_at IS NULL
    LEFT JOIN #{table(opts, "mentions")} m
      ON n.activity_type = 'Mention' AND m.id = n.activity_id
    LEFT JOIN #{table(opts, "statuses")} mentioned
      ON mentioned.id = m.status_id AND mentioned.deleted_at IS NULL
    LEFT JOIN #{table(opts, "favourites")} f
      ON n.activity_type = 'Favourite' AND f.id = n.activity_id
    LEFT JOIN #{table(opts, "statuses")} favourited
      ON favourited.id = f.status_id AND favourited.deleted_at IS NULL
    LEFT JOIN #{table(opts, "polls")} p
      ON n.activity_type = 'Poll' AND p.id = n.activity_id
    LEFT JOIN #{table(opts, "statuses")} polled
      ON polled.id = p.status_id AND polled.deleted_at IS NULL
    WHERE n.type IS NOT NULL
    """

    known = MapSet.new(Notification.types())

    copy(opts, name, Notification, sql, fn row ->
      # A kind of notification this server has no way to render is noise in
      # somebody's list rather than something they lost. The schema version
      # check is what stops that being a silent omission: a source new enough
      # to have invented one is refused before this runs.
      if MapSet.member?(known, row["type"]) do
        notification_row(row)
      end
    end)
  end

  defp notification_row(row) do
    %{
      id: row["id"],
      account_id: row["account_id"],
      from_account_id: row["from_account_id"],
      type: row["type"],
      status_id: row["status_id"],
      # Notifications are shown in groups, and a notification with no group is
      # a group of one. The source leaves the column empty for anything written
      # before grouping existed.
      group_key: presence(row["group_key"]) || "ungrouped-#{row["id"]}",
      filtered: row["filtered"] == true,
      inserted_at: at(row["created_at"]),
      updated_at: at(row["updated_at"])
    }
  end

  ## The small things

  defp copy_notes(opts, name) do
    sql = """
    SELECT * FROM #{table(opts, "account_notes")}
    WHERE account_id IS NOT NULL AND target_account_id IS NOT NULL
    """

    copy(opts, name, Note, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        target_account_id: row["target_account_id"],
        comment: row["comment"] || "",
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_tag_follows(opts, name) do
    sql = "SELECT * FROM #{table(opts, "tag_follows")}"

    copy(opts, name, "tag_follows", sql, fn row ->
      %{
        account_id: row["account_id"],
        tag_id: row["tag_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # No timestamps on the source's rows; the conversation's own creation time
  # stands in, for the same reason a list's does.
  defp copy_conversation_mutes(opts, name) do
    sql = """
    SELECT cm.id, cm.account_id, cm.conversation_id, c.created_at AS created_at
    FROM #{table(opts, "conversation_mutes")} cm
    JOIN #{table(opts, "conversations")} c ON c.id = cm.conversation_id
    """

    copy(opts, name, ConversationMute, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        conversation_id: row["conversation_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["created_at"])
      }
    end)
  end

  ## The enums

  defp replies_policy(1), do: "followed"
  defp replies_policy(2), do: "none"
  defp replies_policy(_list), do: "list"

  # `blur` has no counterpart here. Hiding is the nearer of the two: it is what
  # somebody who did not want to see something asked for, and showing it
  # blurred instead would show it.
  defp filter_action(action) when action in [1, 2], do: "hide"
  defp filter_action(_warn), do: "warn"

  # Numbers over there and the same three words here: let it through, put it in
  # the requests list, or drop it. Collapsing them to a boolean would lose the
  # difference between filtering and dropping.
  defp filter_setting(1), do: "filter"
  defp filter_setting(2), do: "drop"
  defp filter_setting(_accept), do: "accept"

  ## Plumbing

  defp copy(opts, part, target, sql, mapper),
    do: Batch.copy(opts, step_name(part), target, sql, mapper)

  defp step_name(part), do: Batch.step_name(:graph, part)

  defp table(opts, name), do: Source.table(opts, name)

  defp presence(value), do: Source.presence(value)

  defp at(value), do: Source.at(value)
end

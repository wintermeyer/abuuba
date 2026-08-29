defmodule Abuuba.Importer.Content do
  @moduledoc """
  Everything that was posted, and everything hanging off it.

  Statuses keep their ids and their URIs, because both are already published:
  the id is in every permalink and the URI is what every other server on the
  network stored when the post was delivered to it. A post that comes across
  under a new id is a new post as far as the fediverse is concerned, and the
  old one is a dead link in a thousand timelines.

  ## Nothing points at a row that was not copied

  Posts deleted on the source are not copied — they are already gone — and that
  makes every reference to a status a question rather than a value. A reply
  whose parent was deleted, a boost of a deleted post, an attachment on one, a
  favourite of one: each has to be either dropped or emptied, and which of the
  two depends on whether the row means anything without it.

  So every query here joins to the source's own statuses table with the same
  condition the statuses part used. The reference is then true by construction
  rather than true if the ordering happened to work out.

  ## Replies and boosts are filled in afterwards

  A status can point at another status, and a takeover cannot assume which of
  the two was written first. The rows land without those two columns and a
  second pass sets them, which is the same shape the accounts step uses for a
  move. Both passes are checkpointed, so an interruption between them is a
  continuation rather than a hole.

  ## Counters are copied, not recomputed

  The source has already counted, and counting a hundred million rows again to
  arrive at the same numbers is hours of work for no new information.
  """

  @behaviour Abuuba.Importer.Step

  import Ecto.Query

  alias Abuuba.Importer.Batch
  alias Abuuba.Importer.Source
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Storage
  alias Abuuba.PreviewCards.Card
  alias Abuuba.Repo
  alias Abuuba.Stats.AccountStat
  alias Abuuba.Stats.StatusStat
  alias Abuuba.Statuses.Bookmark
  alias Abuuba.Statuses.Conversation
  alias Abuuba.Statuses.Favourite
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Pin
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.PollVote
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.StatusEdit
  alias Abuuba.Statuses.Tag

  @impl Abuuba.Importer.Step
  @spec run(keyword()) :: :ok | {:error, {atom(), term()}}
  def run(opts), do: Batch.run_parts(opts, parts())

  # Tags and conversations first, because a status names both. The two second
  # passes come after everything they can point at.
  defp parts do
    [
      {:tags, &copy_tags/2},
      {:conversations, &copy_conversations/2},
      {:statuses, &copy_statuses/2},
      {:status_links, &copy_status_links/2},
      {:status_tags, &copy_status_tags/2},
      {:status_edits, &copy_status_edits/2},
      {:mentions, &copy_mentions/2},
      {:featured_tags, &copy_featured_tags/2},
      {:favourites, &copy_favourites/2},
      {:bookmarks, &copy_bookmarks/2},
      {:polls, &copy_polls/2},
      {:poll_votes, &copy_poll_votes/2},
      {:status_pins, &copy_pins/2},
      {:account_conversations, &copy_account_conversations/2},
      {:media_attachments, &copy_media/2},
      {:preview_cards, &copy_cards/2},
      {:card_statuses, &copy_card_statuses/2},
      {:status_stats, &copy_status_stats/2},
      {:account_stats, &copy_account_stats/2},
      {:quotes, &copy_quotes/2},
      {:tombstones, &copy_tombstones/2}
    ]
  end

  @doc """
  Counts what came across against what the source holds.

  Statuses are the one thing an admin will check by eye, and "the number is the
  same" is the answer they are looking for. Deleted rows are excluded on both
  sides, because they are excluded from the import.
  """
  @impl Abuuba.Importer.Step
  @spec verify(keyword()) :: [Abuuba.Importer.Step.verification()]
  def verify(opts) do
    [count_check(opts, "statuses", "deleted_at IS NULL", Status)]
  end

  defp count_check(opts, table, where, schema) do
    source = Source.count(opts, table, where)
    here = Repo.aggregate(schema, :count)

    %{
      name: "#{table} copied",
      checked: source,
      failures:
        if(source == here,
          do: [],
          else: [%{id: table, was: source, now: here}]
        )
    }
  end

  ## Tags and conversations

  defp copy_tags(opts, name) do
    copy(opts, name, Tag, "SELECT * FROM #{table(opts, "tags")}", fn row ->
      %{
        id: row["id"],
        name: row["name"],
        display_name: presence(row["display_name"]),
        # Null on the source means nobody has decided. For the two columns that
        # allow it here that reading is kept; for the two that do not, the
        # decision has already been made and it is the permissive one — a tag
        # nobody has ruled on is a tag people may use.
        usable: row["usable"] != false,
        listable: row["listable"] != false,
        trendable: row["trendable"],
        reviewed_at: at(row["reviewed_at"]),
        requested_review_at: at(row["requested_review_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_conversations(opts, name) do
    sql = "SELECT * FROM #{table(opts, "conversations")}"

    copy(opts, name, Conversation, sql, fn row ->
      %{
        id: row["id"],
        uri: presence(row["uri"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  ## Statuses

  defp copy_statuses(opts, name) do
    sql = "SELECT * FROM #{table(opts, "statuses")} WHERE deleted_at IS NULL"

    copy(opts, name, Status, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        uri: presence(row["uri"]),
        url: presence(row["url"]),
        # The column is nullable and older rows leave it empty; the source's own
        # rule is that a status with no URI of somebody else's is one of ours.
        # Reading it wrongly would leave a local post that never federates.
        local: row["local"] == true or is_nil(presence(row["uri"])),
        text: row["text"] || "",
        spoiler_text: row["spoiler_text"] || "",
        language: presence(row["language"]),
        sensitive: row["sensitive"] == true,
        visibility: visibility(row["visibility"]),
        quote_policy: quote_policy(row["quote_approval_policy"]),
        # The two self-references are set by the second pass; see the module
        # documentation.
        in_reply_to_account_id: row["in_reply_to_account_id"],
        conversation_id: row["conversation_id"],
        ordered_media_attachment_ids: row["ordered_media_attachment_ids"] || [],
        edited_at: at(row["edited_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # Both columns at once, and only where the target survived. A reply whose
  # parent was deleted is still the reply somebody wrote; it just has nothing
  # to hang under any more.
  defp copy_status_links(opts, name) do
    sql = """
    SELECT s.id,
           parent.id AS in_reply_to_id,
           original.id AS reblog_of_id
    FROM #{table(opts, "statuses")} s
    LEFT JOIN #{table(opts, "statuses")} parent
      ON parent.id = s.in_reply_to_id AND parent.deleted_at IS NULL
    LEFT JOIN #{table(opts, "statuses")} original
      ON original.id = s.reblog_of_id AND original.deleted_at IS NULL
    WHERE s.deleted_at IS NULL
      AND (s.in_reply_to_id IS NOT NULL OR s.reblog_of_id IS NOT NULL)
    """

    page(opts, name, Status, sql, fn rows ->
      Enum.each(rows, fn row ->
        Status
        |> where([s], s.id == ^row["id"])
        |> Repo.update_all(
          set: [in_reply_to_id: row["in_reply_to_id"], reblog_of_id: row["reblog_of_id"]]
        )
      end)

      {:ok, []}
    end)
  end

  # Paged over statuses rather than over the join table, which has no id of its
  # own: paging on one half of a composite key drops whatever else shares it
  # across a page boundary.
  defp copy_status_tags(opts, name) do
    sql = "SELECT id FROM #{table(opts, "statuses")} WHERE deleted_at IS NULL"

    page(opts, name, "statuses_tags", sql, fn statuses ->
      joined(opts, "statuses_tags", Enum.map(statuses, & &1["id"]), fn row ->
        %{status_id: row["status_id"], tag_id: row["tag_id"]}
      end)
    end)
  end

  defp copy_card_statuses(opts, name) do
    sql = "SELECT id FROM #{table(opts, "statuses")} WHERE deleted_at IS NULL"

    page(opts, name, "preview_cards_statuses", sql, fn statuses ->
      joined(opts, "preview_cards_statuses", Enum.map(statuses, & &1["id"]), fn row ->
        %{status_id: row["status_id"], preview_card_id: row["preview_card_id"]}
      end)
    end)
  end

  defp joined(_opts, _table, [], _mapper), do: {:ok, []}

  defp joined(opts, source_table, status_ids, mapper) do
    sql = "SELECT * FROM #{table(opts, source_table)} WHERE status_id = ANY($1)"

    case Source.rows(opts, sql, [status_ids]) do
      {:ok, rows} -> {:ok, Enum.map(rows, mapper)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_status_edits(opts, name) do
    sql = """
    SELECT e.* FROM #{table(opts, "status_edits")} e
    JOIN #{table(opts, "statuses")} s ON s.id = e.status_id AND s.deleted_at IS NULL
    """

    copy(opts, name, StatusEdit, sql, fn row ->
      %{
        id: row["id"],
        status_id: row["status_id"],
        account_id: row["account_id"],
        text: row["text"] || "",
        spoiler_text: row["spoiler_text"] || "",
        sensitive: row["sensitive"] == true,
        ordered_media_attachment_ids: row["ordered_media_attachment_ids"] || [],
        media_descriptions: row["media_descriptions"] || [],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_mentions(opts, name) do
    sql = """
    SELECT m.* FROM #{table(opts, "mentions")} m
    JOIN #{table(opts, "statuses")} s ON s.id = m.status_id AND s.deleted_at IS NULL
    WHERE m.account_id IS NOT NULL
    """

    copy(opts, name, Mention, sql, fn row ->
      %{
        id: row["id"],
        status_id: row["status_id"],
        account_id: row["account_id"],
        silent: row["silent"] == true,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_featured_tags(opts, name) do
    sql = """
    SELECT f.* FROM #{table(opts, "featured_tags")} f
    WHERE f.account_id IS NOT NULL AND f.tag_id IS NOT NULL
    """

    copy(opts, name, "featured_tags", sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        tag_id: row["tag_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_favourites(opts, name) do
    copy(opts, name, Favourite, status_scoped(opts, "favourites"), fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        status_id: row["status_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_bookmarks(opts, name) do
    copy(opts, name, Bookmark, status_scoped(opts, "bookmarks"), fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        status_id: row["status_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_pins(opts, name) do
    copy(opts, name, Pin, status_scoped(opts, "status_pins"), fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        status_id: row["status_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # The rows that are meaningless without their status, so they are dropped
  # rather than emptied.
  defp status_scoped(opts, source_table) do
    """
    SELECT t.* FROM #{table(opts, source_table)} t
    JOIN #{table(opts, "statuses")} s ON s.id = t.status_id AND s.deleted_at IS NULL
    """
  end

  defp copy_polls(opts, name) do
    copy(opts, name, Poll, status_scoped(opts, "polls"), fn row ->
      %{
        id: row["id"],
        status_id: row["status_id"],
        account_id: row["account_id"],
        options: row["options"] || [],
        # Named for what they are here. The source calls them cached because it
        # recounts them; both hold the same numbers.
        tallies: row["cached_tallies"] || [],
        expires_at: at(row["expires_at"]),
        multiple: row["multiple"] == true,
        voters_count: row["voters_count"] || 0,
        last_fetched_at: at(row["last_fetched_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_poll_votes(opts, name) do
    sql = """
    SELECT v.* FROM #{table(opts, "poll_votes")} v
    JOIN #{table(opts, "polls")} p ON p.id = v.poll_id
    JOIN #{table(opts, "statuses")} s ON s.id = p.status_id AND s.deleted_at IS NULL
    WHERE v.account_id IS NOT NULL
    """

    copy(opts, name, PollVote, sql, fn row ->
      %{
        id: row["id"],
        poll_id: row["poll_id"],
        account_id: row["account_id"],
        choice: row["choice"] || 0,
        uri: presence(row["uri"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_account_conversations(opts, name) do
    sql = """
    SELECT c.*, last.id AS last_status_id
    FROM #{table(opts, "account_conversations")} c
    LEFT JOIN #{table(opts, "statuses")} last
      ON last.id = c.last_status_id AND last.deleted_at IS NULL
    WHERE c.account_id IS NOT NULL AND c.conversation_id IS NOT NULL
    """

    copy(opts, name, "account_conversations", sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        conversation_id: row["conversation_id"],
        participant_account_ids: row["participant_account_ids"] || [],
        status_ids: row["status_ids"] || [],
        last_status_id: row["last_status_id"],
        unread: row["unread"] == true,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  ## Media and cards

  # The file columns come across as they are, because the file tree is copied
  # as it is: abuuba lays media out the way Mastodon does, down to the id
  # partitioning, so a row that named a file over there names the same file
  # here.
  defp copy_media(opts, name) do
    sql = """
    SELECT m.*, s.id AS status_id
    FROM #{table(opts, "media_attachments")} m
    LEFT JOIN #{table(opts, "statuses")} s
      ON s.id = m.status_id AND s.deleted_at IS NULL
    """

    copy(opts, name, Attachment, sql, fn row ->
      %{
        id: row["id"],
        status_id: row["status_id"],
        account_id: row["account_id"],
        type: media_type(row["type"]),
        processing: processing(row["processing"]),
        file_file_name: presence(row["file_file_name"]),
        file_content_type: presence(row["file_content_type"]),
        file_file_size: row["file_file_size"],
        thumbnail_file_name: presence(row["thumbnail_file_name"]),
        thumbnail_content_type: presence(row["thumbnail_content_type"]),
        thumbnail_file_size: row["thumbnail_file_size"],
        meta: meta(row["file_meta"]),
        blurhash: presence(row["blurhash"]),
        description: presence(row["description"]),
        # Empty rather than null: an empty string is what says "this server
        # holds this file", and both sides spell it the same way.
        remote_url: row["remote_url"] || "",
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # A json column, so it arrives decoded. A string means an older row that kept
  # the same thing as text, and one that will not parse means nothing worth
  # keeping: the dimensions are re-derivable from the file.
  defp meta(meta) when is_map(meta), do: meta

  defp meta(meta) when is_binary(meta) do
    case Jason.decode(meta) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _not_json -> %{}
    end
  end

  defp meta(_missing), do: %{}

  defp copy_cards(opts, name) do
    sql = "SELECT * FROM #{table(opts, "preview_cards")}"

    copy(opts, name, Card, sql, fn row ->
      %{
        id: row["id"],
        url: row["url"],
        title: row["title"] || "",
        description: row["description"] || "",
        type: card_type(row["type"]),
        author_name: presence(row["author_name"]),
        author_url: presence(row["author_url"]),
        provider_name: presence(row["provider_name"]),
        provider_url: presence(row["provider_url"]),
        author_account_id: row["author_account_id"],
        html: row["html"] || "",
        width: row["width"] || 0,
        height: row["height"] || 0,
        # A URL here, file columns there. The file itself is in the tree that
        # is copied, under the path the source gave it.
        image_url: card_image_url(row),
        image_description: presence(row["image_description"]),
        blurhash: presence(row["blurhash"]),
        embed_url: row["embed_url"] || "",
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp card_image_url(%{"image_file_name" => name} = row) when is_binary(name) and name != "" do
    Storage.url("preview_cards/images/#{Storage.partition(row["id"])}/original/#{name}")
  end

  defp card_image_url(_no_image), do: nil

  ## Counters

  defp copy_status_stats(opts, name) do
    sql = """
    SELECT t.* FROM #{table(opts, "status_stats")} t
    JOIN #{table(opts, "statuses")} s ON s.id = t.status_id AND s.deleted_at IS NULL
    """

    copy(opts, name, StatusStat, sql, fn row ->
      %{
        status_id: row["status_id"],
        replies_count: row["replies_count"] || 0,
        reblogs_count: row["reblogs_count"] || 0,
        favourites_count: row["favourites_count"] || 0,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_account_stats(opts, name) do
    sql = "SELECT * FROM #{table(opts, "account_stats")}"

    copy(opts, name, AccountStat, sql, fn row ->
      %{
        account_id: row["account_id"],
        statuses_count: row["statuses_count"] || 0,
        following_count: row["following_count"] || 0,
        followers_count: row["followers_count"] || 0,
        last_status_at: at(row["last_status_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  ## Quotes and tombstones

  defp copy_quotes(opts, name) do
    sql = """
    SELECT q.*, quoted.id AS quoted_status_id, quoted.uri AS quoted_status_uri
    FROM #{table(opts, "quotes")} q
    JOIN #{table(opts, "statuses")} s ON s.id = q.status_id AND s.deleted_at IS NULL
    LEFT JOIN #{table(opts, "statuses")} quoted
      ON quoted.id = q.quoted_status_id AND quoted.deleted_at IS NULL
    """

    copy(opts, name, "quotes", sql, fn row ->
      %{
        id: row["id"],
        status_id: row["status_id"],
        quoted_status_id: row["quoted_status_id"],
        # The quoted post's own address. Empty where the quoted post is one of
        # ours, which has no URI of somebody else's to record.
        quoted_status_uri: row["quoted_status_uri"] || "",
        approval_uri: presence(row["approval_uri"]),
        state: quote_state(row["state"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # What the source remembers about posts that are gone, so that a delete which
  # already federated is not undone by an import that has never heard of it.
  defp copy_tombstones(opts, name) do
    sql = "SELECT * FROM #{table(opts, "tombstones")}"

    copy(opts, name, "tombstones", sql, fn row ->
      %{
        uri: row["uri"],
        kind: if(row["by_moderator"] == true, do: "moderator", else: "author"),
        inserted_at: at(row["created_at"])
      }
    end)
  end

  ## The enums

  # Stored as numbers over there and as words here. The numbers are the
  # protocol's rather than either project's, so they are read rather than
  # guessed, and anything unrecognised takes the safest reading: a post nobody
  # asked to be public stays private.
  defp visibility(0), do: :public
  defp visibility(1), do: :unlisted
  defp visibility(2), do: :private
  defp visibility(3), do: :direct
  defp visibility(4), do: :limited
  defp visibility(_unknown), do: :private

  # A bitmap over there, split into an automatic half and a manual one. Only
  # the automatic half has a counterpart here: abuuba asks who may quote without
  # asking first, which is the same question the top sixteen bits answer.
  #
  # Zero is not "unset". It is what the source writes for "nobody", what every
  # post written before quoting existed carries, and what every private, direct
  # and limited post is downgraded to on save. Reading it as public would open
  # all three to being quoted by anybody.
  # 1 <<< 1 and 1 <<< 2, written out because these are the source's numbers and
  # not something to recompute.
  @policy_public 2
  @policy_followers 4

  defp quote_policy(policy) when is_integer(policy) do
    automatic = Bitwise.bsr(policy, 16)

    cond do
      Bitwise.band(automatic, @policy_public) != 0 -> :public
      Bitwise.band(automatic, @policy_followers) != 0 -> :followers
      true -> :nobody
    end
  end

  # A source old enough not to have the column is one where quoting did not
  # exist, so nobody could quote anything.
  defp quote_policy(_missing), do: :nobody

  defp media_type(0), do: :image
  defp media_type(1), do: :gifv
  defp media_type(2), do: :video
  defp media_type(4), do: :audio
  defp media_type(_unknown), do: :unknown

  defp processing(0), do: :queued
  defp processing(1), do: :in_progress
  defp processing(3), do: :failed
  # Null means an older row that predates the column, and those are all
  # finished: nothing has been processing since before the column existed.
  defp processing(_complete), do: :complete

  defp card_type(1), do: "photo"
  defp card_type(2), do: "video"
  # `rich` has no counterpart here and is rendered as a plain link, which is
  # what abuuba does with one anyway.
  defp card_type(_link), do: "link"

  defp quote_state(1), do: "accepted"
  defp quote_state(2), do: "rejected"
  # A quote the source deleted is one that no longer stands, which is what
  # revoked means here.
  defp quote_state(state) when state in [3, 4], do: "revoked"
  defp quote_state(_pending), do: "pending"

  ## Plumbing

  defp copy(opts, part, target, sql, mapper),
    do: Batch.copy(opts, step_name(part), target, sql, mapper)

  defp page(opts, part, target, sql, builder),
    do: Batch.page(opts, step_name(part), target, sql, builder)

  defp step_name(part), do: Batch.step_name(:content, part)

  defp table(opts, name), do: Source.table(opts, name)

  defp presence(value), do: Source.presence(value)

  defp at(value), do: Source.at(value)
end

defmodule Abuuba.Importer.ContentTest do
  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts.Account
  alias Abuuba.Importer.Content
  alias Abuuba.MastodonSource, as: Source
  alias Abuuba.Media.Attachment
  alias Abuuba.Repo
  alias Abuuba.Stats.AccountStat
  alias Abuuba.Stats.StatusStat
  alias Abuuba.Statuses.Favourite
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag

  setup do
    Source.create!()
    # The accounts step has already run by the time this one does, so its rows
    # are here rather than being copied again: a status without its author is a
    # foreign key violation, not a test fixture.
    Repo.insert_all(Account, [
      %{
        id: 1,
        username: "alice",
        uri: "https://here.example/users/alice",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    seed!()

    on_exit(&Source.drop!/0)

    :ok
  end

  defp opts, do: [repo: Repo, prefix: Source.prefix()]

  describe "statuses" do
    test "keep their ids and their URIs, which are already published" do
      :ok = Content.run(opts())

      status = Repo.get(Status, 10)

      assert status.uri == "https://here.example/users/alice/statuses/10"
      assert status.text == "<p>hello</p>"
      assert status.account_id == 1
    end

    test "keep their visibility, and an unknown one is read as the safest" do
      # Reading a visibility wrongly is the difference between a private post
      # and a public one, so anything this code does not recognise is treated
      # as the more private of the two.
      :ok = Content.run(opts())

      assert Repo.get(Status, 10).visibility == :public
      assert Repo.get(Status, 11).visibility == :private
      assert Repo.get(Status, 15).visibility == :private
    end

    test "leave behind what the source had already deleted" do
      :ok = Content.run(opts())

      assert is_nil(Repo.get(Status, 13))
    end

    test "keep threading and boosts" do
      :ok = Content.run(opts())

      assert Repo.get(Status, 11).in_reply_to_id == 10
      assert Repo.get(Status, 12).reblog_of_id == 10
    end

    test "a reply to a deleted post keeps the reply and drops the thread" do
      # The parent is gone, so there is nothing to point at. Refusing the row
      # would lose a post somebody wrote; pointing at a row that is not there
      # is a foreign key violation that takes the batch with it.
      :ok = Content.run(opts())

      orphan = Repo.get(Status, 14)

      assert orphan
      assert is_nil(orphan.in_reply_to_id)
    end

    test "a post with no URI of somebody else's is one of ours" do
      # The column is nullable and older rows leave it empty. Reading it as
      # remote would leave a local post that never federates again.
      :ok = Content.run(opts())

      assert Repo.get(Status, 11).local
      refute Repo.get(Status, 16).local
    end

    test "keep the conversation a thread belongs to" do
      :ok = Content.run(opts())

      assert Repo.get(Status, 10).conversation_id == 900
    end

    test "keep who may quote them" do
      :ok = Content.run(opts())

      assert Repo.get(Status, 17).quote_policy == :public
      assert Repo.get(Status, 15).quote_policy == :followers
    end

    test "and an empty policy is nobody, not everybody" do
      # Zero is what the source writes for "nobody may quote this", and it is
      # also what every post written before quoting existed carries, and what
      # every private post is downgraded to. Reading it as public would open
      # all three to being quoted.
      :ok = Content.run(opts())

      assert Repo.get(Status, 10).quote_policy == :nobody
    end

    test "run twice without doubling anything" do
      :ok = Content.run(opts())
      :ok = Content.run(opts())

      assert Repo.aggregate(Status, :count) == 7
    end
  end

  describe "everything hanging off a status" do
    test "tags come across, and so does what a post was tagged with" do
      :ok = Content.run(opts())

      assert %Tag{name: "caturday"} = Repo.get(Tag, 800)

      assert [[10, 800]] =
               Repo.query!("SELECT status_id, tag_id FROM statuses_tags ORDER BY status_id").rows
    end

    test "favourites and bookmarks of deleted posts are not copied" do
      :ok = Content.run(opts())

      assert Repo.get(Favourite, 500)
      refute Repo.get(Favourite, 501)
    end

    test "polls keep their options and their tallies" do
      :ok = Content.run(opts())

      poll = Repo.get(Poll, 700)

      assert poll.options == ["yes", "no"]
      assert poll.tallies == [3, 1]
      assert poll.status_id == 15
    end

    test "media keeps the file columns, because the file tree is copied as is" do
      :ok = Content.run(opts())

      media = Repo.get(Attachment, 600)

      assert media.file_file_name == "picture.jpg"
      assert media.type == :image
      assert media.processing == :complete
      assert media.status_id == 10
      assert media.meta["original"]["width"] == 640
    end

    test "media on a deleted post keeps the file and forgets the post" do
      :ok = Content.run(opts())

      assert %Attachment{status_id: nil} = Repo.get(Attachment, 601)
    end

    test "a preview card points at the image the source stored" do
      :ok = Content.run(opts())

      card = Repo.get(Abuuba.PreviewCards.Card, 650)

      assert card.title == "A link"
      assert card.type == "link"
      assert card.image_url =~ "preview_cards/images/000/000/650/original/card.png"
    end

    test "counters come across rather than being counted again" do
      :ok = Content.run(opts())

      assert %StatusStat{favourites_count: 12, reblogs_count: 3} = Repo.get(StatusStat, 10)
      assert %AccountStat{statuses_count: 42, followers_count: 7} = Repo.get(AccountStat, 1)
    end

    test "a tombstone keeps a delete that already federated" do
      :ok = Content.run(opts())

      assert [["https://here.example/users/alice/statuses/13", "author"]] =
               Repo.query!("SELECT uri, kind FROM tombstones").rows
    end
  end

  describe "verification" do
    test "counts what came across against what the source holds" do
      :ok = Content.run(opts())

      assert [%{name: "statuses copied", checked: 7, failures: []}] = Content.verify(opts())
    end

    test "says so when a status did not make it" do
      :ok = Content.run(opts())

      Repo.delete_all(from(s in Status, where: s.id == 15))

      assert [%{failures: [%{was: 7, now: 6}]}] = Content.verify(opts())
    end
  end

  ## The source

  defp seed! do
    Source.insert!("accounts", %{
      "id" => 1,
      "username" => "alice",
      "uri" => "https://here.example/users/alice",
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("conversations", %{
      "id" => 900,
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    status = fn attrs ->
      Source.insert!(
        "statuses",
        Map.merge(
          %{
            "account_id" => 1,
            "created_at" => ~N[2026-01-01 00:00:00],
            "updated_at" => ~N[2026-01-01 00:00:00]
          },
          attrs
        )
      )
    end

    status.(%{
      "id" => 10,
      "uri" => "https://here.example/users/alice/statuses/10",
      "text" => "<p>hello</p>",
      "visibility" => 0,
      "conversation_id" => 900
    })

    status.(%{
      "id" => 11,
      "visibility" => 2,
      "in_reply_to_id" => 10,
      "in_reply_to_account_id" => 1
    })

    status.(%{"id" => 12, "reblog_of_id" => 10})
    status.(%{"id" => 13, "deleted_at" => ~N[2026-01-02 00:00:00]})
    status.(%{"id" => 14, "in_reply_to_id" => 13})
    # 99 is a visibility this code has never seen.
    status.(%{"id" => 15, "visibility" => 99, "quote_approval_policy" => 4 * 65_536})
    # Somebody else's post, with the null `local` column an older row has.
    status.(%{"id" => 16, "uri" => "https://other.example/users/carol/statuses/16"})
    status.(%{"id" => 17, "quote_approval_policy" => 2 * 65_536})

    Source.insert!("tags", %{
      "id" => 800,
      "name" => "caturday",
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("statuses_tags", %{"status_id" => 10, "tag_id" => 800})
    # On a post nobody kept, so it must not come across either.
    Source.insert!("statuses_tags", %{"status_id" => 13, "tag_id" => 800})

    Source.insert!("favourites", %{
      "id" => 500,
      "account_id" => 1,
      "status_id" => 10,
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("favourites", %{
      "id" => 501,
      "account_id" => 1,
      "status_id" => 13,
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("polls", %{
      "id" => 700,
      "account_id" => 1,
      "status_id" => 15,
      "options" => ["yes", "no"],
      "cached_tallies" => [3, 1],
      "voters_count" => 4,
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("media_attachments", %{
      "id" => 600,
      "status_id" => 10,
      "account_id" => 1,
      "file_file_name" => "picture.jpg",
      "file_content_type" => "image/jpeg",
      "file_file_size" => 1000,
      "type" => 0,
      "processing" => 2,
      "file_meta" => %{"original" => %{"width" => 640, "height" => 480}},
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("media_attachments", %{
      "id" => 601,
      "status_id" => 13,
      "account_id" => 1,
      "file_file_name" => "gone.jpg",
      "type" => 0,
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("preview_cards", %{
      "id" => 650,
      "url" => "https://example.com/a",
      "title" => "A link",
      "description" => "",
      "type" => 0,
      "image_file_name" => "card.png",
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("preview_cards_statuses", %{"preview_card_id" => 650, "status_id" => 10})

    Source.insert!("status_stats", %{
      "id" => 1,
      "status_id" => 10,
      "favourites_count" => 12,
      "reblogs_count" => 3,
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("account_stats", %{
      "id" => 1,
      "account_id" => 1,
      "statuses_count" => 42,
      "followers_count" => 7,
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })

    Source.insert!("tombstones", %{
      "id" => 1,
      "account_id" => 1,
      "uri" => "https://here.example/users/alice/statuses/13",
      "by_moderator" => false,
      "created_at" => ~N[2026-01-01 00:00:00],
      "updated_at" => ~N[2026-01-01 00:00:00]
    })
  end
end

defmodule Abuuba.StatusesTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Relationships
  alias Abuuba.Snowflake
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Conversation
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag
  alias Abuuba.Streaming
  alias Abuuba.Timelines.Feed

  describe "a content warning" do
    test "makes the post sensitive, whatever the client said" do
      # Every reader decides whether to open a warned post by that flag: an app
      # blurs the picture behind it, and so does every server we deliver to.
      account = account_fixture()

      {:ok, status} =
        Statuses.create_status(%{
          account_id: account.id,
          text: "the body",
          spoiler_text: "a warning",
          sensitive: false
        })

      assert status.sensitive
    end

    test "and a post without one is left alone" do
      # The control: a version that simply set `sensitive` on everything would
      # satisfy the test above.
      account = account_fixture()

      {:ok, status} = Statuses.create_status(%{account_id: account.id, text: "no warning"})

      refute status.sensitive
    end

    test "and adding one in an edit makes it sensitive too" do
      account = account_fixture()
      {:ok, status} = Statuses.create_status(%{account_id: account.id, text: "the body"})
      refute status.sensitive

      {:ok, edited} = Statuses.edit_status(status, %{"spoiler_text" => "on reflection"})

      assert edited.sensitive
    end

    test "but somebody else's post keeps what their server decided" do
      # A remote post carries its own server's answer. Deciding differently on
      # their behalf would be answering for them.
      remote = remote_account_fixture(%{username: "far", domain: "far.example"})

      {:ok, status} =
        Statuses.create_status(%{
          account_id: remote.id,
          local: false,
          uri: "https://far.example/statuses/1",
          text: "theirs",
          spoiler_text: "their warning",
          sensitive: false
        })

      refute status.sensitive
    end
  end

  describe "create_status/1" do
    test "takes a snowflake id from the database" do
      status = status_fixture()

      assert status.id > 0

      assert DateTime.diff(Snowflake.to_time(status.id), DateTime.utc_now(), :second) |> abs() <
               60
    end

    test "defaults to a public, non-sensitive, local post" do
      status = status_fixture()

      assert status.visibility == :public
      refute status.sensitive
      assert status.local
      assert status.deleted_at == nil
      assert status.edited_at == nil
    end

    test "accepts every visibility the API knows" do
      for visibility <- ~w(public unlisted private direct limited)a do
        assert %{visibility: ^visibility} = status_fixture(%{visibility: visibility})
      end
    end

    test "refuses a visibility it does not know" do
      assert {:error, changeset} =
               Statuses.create_status(%{account_id: account_fixture().id, visibility: :secret})

      assert errors_on(changeset).visibility != []
    end

    test "refuses text longer than 500 characters" do
      assert {:error, changeset} =
               Statuses.create_status(%{
                 account_id: account_fixture().id,
                 text: String.duplicate("a", 501)
               })

      assert errors_on(changeset).text != []
    end

    test "keeps the author's ordering of attachments" do
      status = status_fixture(%{ordered_media_attachment_ids: [30, 10, 20]})

      assert Repo.get!(Status, status.id).ordered_media_attachment_ids == [30, 10, 20]
    end

    test "refuses a language tag that is not one" do
      for bad <- ["english", "e", "12", "de_DE"] do
        assert {:error, changeset} =
                 Statuses.create_status(%{account_id: account_fixture().id, language: bad})

        assert errors_on(changeset).language != [], "accepted #{bad}"
      end
    end

    test "accepts a language tag with a region" do
      assert %{language: "de-AT"} = status_fixture(%{language: "de-AT"})
    end

    test "a uri may be claimed only once" do
      status_fixture(%{uri: "https://remote.example/statuses/1", local: false})

      assert {:error, changeset} =
               Statuses.create_status(%{
                 account_id: account_fixture().id,
                 uri: "https://remote.example/statuses/1"
               })

      assert errors_on(changeset).uri != []
    end

    test "several local statuses may all still be waiting for a uri" do
      status_fixture(%{uri: nil})

      assert %{uri: nil} = status_fixture(%{uri: nil})
    end
  end

  describe "soft delete" do
    test "hides the status from the default query but keeps the row" do
      status = status_fixture()

      assert {:ok, deleted} = Statuses.delete_status(status)
      assert Status.deleted?(deleted)

      assert Statuses.get_status(status.id, nil) == nil
      assert Repo.get!(Status, status.id).id == status.id
      assert Statuses.with_deleted() |> Repo.get(status.id)
    end

    test "keeps a deleted status out of the public timeline" do
      status = status_fixture()
      Statuses.delete_status(status)

      refute status.id in Enum.map(Statuses.public_timeline(), & &1.id)
    end
  end

  describe "boosts" do
    test "are statuses pointing at the original" do
      original = status_fixture()
      booster = account_fixture()

      assert {:ok, boost} = Statuses.boost(booster, original)
      assert Status.boost?(boost)
      assert boost.reblog_of_id == original.id
      assert boost.account_id == booster.id
      assert boost.text == ""
    end

    test "a boost of a boost points at the original, not the middle one" do
      original = status_fixture()
      {:ok, first} = Statuses.boost(account_fixture(), original)
      {:ok, second} = Statuses.boost(account_fixture(), first)

      assert second.reblog_of_id == original.id
    end

    test "an account can boost a status only once" do
      original = status_fixture()
      booster = account_fixture()

      {:ok, _} = Statuses.boost(booster, original)

      assert {:error, changeset} = Statuses.boost(booster, original)
      assert errors_on(changeset).account_id != []
    end

    test "two accounts can each boost the same status" do
      original = status_fixture()

      {:ok, _} = Statuses.boost(account_fixture(), original)
      assert {:ok, _} = Statuses.boost(account_fixture(), original)
    end

    test "carry no text, since no renderer would ever show it" do
      original = status_fixture()

      assert {:error, changeset} =
               Statuses.create_status(%{
                 account_id: account_fixture().id,
                 reblog_of_id: original.id,
                 text: "my own commentary"
               })

      assert errors_on(changeset).text != []
    end

    test "disappear when the boosted status is really deleted" do
      original = status_fixture()
      {:ok, boost} = Statuses.boost(account_fixture(), original)

      Repo.delete!(original)

      assert Repo.get(Status, boost.id) == nil
    end
  end

  describe "threading" do
    test "a reply points at its parent and at the parent's author" do
      parent = status_fixture()

      reply =
        status_fixture(%{in_reply_to_id: parent.id, in_reply_to_account_id: parent.account_id})

      assert Status.reply?(reply)
      assert reply.in_reply_to_id == parent.id
      assert reply.in_reply_to_account_id == parent.account_id
    end

    test "a reply outlives the deletion of what it replied to" do
      parent = status_fixture()
      reply = status_fixture(%{in_reply_to_id: parent.id})

      Repo.delete!(parent)

      reloaded = Repo.get!(Status, reply.id)
      assert reloaded.id == reply.id
      assert reloaded.in_reply_to_id == nil
    end

    test "a conversation gathers a thread in order" do
      conversation = conversation_fixture()
      first = status_fixture(%{conversation_id: conversation.id})
      second = status_fixture(%{conversation_id: conversation.id, in_reply_to_id: first.id})

      assert Enum.map(Statuses.conversation_statuses(conversation, nil), & &1.id) ==
               [first.id, second.id]
    end

    test "a remote thread uri is claimed once and then reused" do
      uri = "https://remote.example/contexts/1"

      {:ok, first} = Statuses.upsert_conversation(uri)
      {:ok, again} = Statuses.upsert_conversation(uri)

      assert first.id == again.id
      refute Conversation.local?(first)
    end

    test "a local conversation has no uri, and two of them are distinct" do
      first = conversation_fixture()
      second = conversation_fixture()

      assert Conversation.local?(first)
      refute first.id == second.id
    end
  end

  describe "who may read a status" do
    setup do
      author = account_fixture()
      addressed = account_fixture()
      stranger = account_fixture()

      %{author: author, addressed: addressed, stranger: stranger}
    end

    test "anyone may read a public or unlisted status", context do
      for visibility <- [:public, :unlisted] do
        status = status_fixture(%{account_id: context.author.id, visibility: visibility})

        assert Statuses.get_status(status.id, nil)
        assert Statuses.get_status(status.id, context.stranger)
      end
    end

    test "a stranger may not read a direct, private or limited status", context do
      for visibility <- [:direct, :private, :limited] do
        status = status_fixture(%{account_id: context.author.id, visibility: visibility})

        refute Statuses.get_status(status.id, nil),
               "a logged out reader got a #{visibility} status"

        refute Statuses.get_status(status.id, context.stranger),
               "a stranger got a #{visibility} status"
      end
    end

    test "the author always may", context do
      for visibility <- [:direct, :private, :limited] do
        status = status_fixture(%{account_id: context.author.id, visibility: visibility})

        assert Statuses.get_status(status.id, context.author)
      end
    end

    test "an addressed account may", context do
      status = status_fixture(%{account_id: context.author.id, visibility: :direct})
      {:ok, _} = Statuses.mention(status, context.addressed)

      assert Statuses.get_status(status.id, context.addressed)
      refute Statuses.get_status(status.id, context.stranger)
    end

    test "a direct message never leaks through a thread", context do
      conversation = conversation_fixture()

      public =
        status_fixture(%{account_id: context.author.id, conversation_id: conversation.id})

      secret =
        status_fixture(%{
          account_id: context.author.id,
          conversation_id: conversation.id,
          visibility: :direct
        })

      ids = Enum.map(Statuses.conversation_statuses(conversation, context.stranger), & &1.id)

      assert public.id in ids
      refute secret.id in ids

      assert secret.id in Enum.map(
               Statuses.conversation_statuses(conversation, context.author),
               & &1.id
             )
    end

    test "a direct message never leaks through a hashtag", context do
      tag = tag_fixture()
      secret = status_fixture(%{account_id: context.author.id, visibility: :direct})
      Statuses.tag_status(secret, tag)

      refute secret.id in Enum.map(Statuses.tag_timeline(tag), & &1.id)
      refute secret.id in Enum.map(Statuses.tag_timeline(tag, viewer: context.stranger), & &1.id)

      assert secret.id in Enum.map(Statuses.tag_timeline(tag, viewer: context.author), & &1.id)
    end

    test "the unchecked read is the only way past the rule, and says so", context do
      status = status_fixture(%{account_id: context.author.id, visibility: :direct})

      refute Statuses.get_status(status.id, context.stranger)
      assert Statuses.get_status_unchecked(status.id).id == status.id
    end
  end

  describe "readable/2, the door a reader comes through" do
    setup do
      author = account_fixture()
      reader = account_fixture()

      %{author: author, reader: reader}
    end

    test "answers the same audience question get_status/2 does", %{author: author} do
      public = status_fixture(%{account_id: author.id})
      secret = status_fixture(%{account_id: author.id, visibility: :direct})

      assert Statuses.readable(public.id, nil)
      assert Statuses.readable(secret.id, author)
      refute Statuses.readable(secret.id, nil)
      refute Statuses.readable(nil, author)
    end

    test "and the block question get_status/2 does not", %{author: author, reader: reader} do
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(author, reader)

      assert Statuses.get_status(status.id, reader), "the audience gate lets it through"
      refute Statuses.readable(status.id, reader)
    end

    test "a boost of somebody who blocked the reader is refused too", %{
      author: author,
      reader: reader
    } do
      original = status_fixture(%{account_id: author.id})
      booster = account_fixture()
      {:ok, boost} = Statuses.boost(booster, original)
      {:ok, _} = Relationships.block(author, reader)

      refute Statuses.readable(boost.id, reader),
             "a third party passing the words along does not undo the block"
    end

    test "the reader's own blocks and mutes do not close a link they followed", %{
      author: author,
      reader: reader
    } do
      # "The one place you still see them is their own profile, if you go and
      # look" -- docs/user/safety.md. A profile that lists a post whose link
      # answers nothing breaks that promise, and a mute is the softer tool
      # still. All three say what may be delivered, not what may be opened.
      blocked = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(reader, author)

      muted_author = account_fixture()
      muted = status_fixture(%{account_id: muted_author.id})
      {:ok, _} = Relationships.mute(reader, muted_author)

      elsewhere = remote_account_fixture()
      abroad = status_fixture(%{account_id: elsewhere.id})
      {:ok, _} = Relationships.block_domain(reader, elsewhere.domain)

      conversation = conversation_fixture()
      thread = status_fixture(%{account_id: author.id, conversation_id: conversation.id})
      {:ok, _} = Statuses.mute_thread(reader, thread)

      for status <- [blocked, muted, abroad, thread] do
        assert Statuses.readable(status.id, reader)
        refute Statuses.readable?(status, reader), "and none of them is delivered"
      end
    end

    test "readable?/2 refuses what the audience refuses", %{author: author, reader: reader} do
      secret = status_fixture(%{account_id: author.id, visibility: :direct})

      refute Statuses.readable?(secret, reader)
      refute Statuses.readable?(secret, nil)
      assert Statuses.readable?(secret, author)
    end

    test "readable_many/2 keeps the caller's order and drops what is refused", %{
      author: author,
      reader: reader
    } do
      first = status_fixture(%{account_id: author.id})
      refuser = account_fixture()
      refused = status_fixture(%{account_id: refuser.id})
      last = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(refuser, reader)

      ids = [last.id, refused.id, first.id]

      assert Enum.map(Statuses.readable_many(ids, reader), & &1.id) == [last.id, first.id]
      assert Statuses.readable_many([], reader) == []
    end

    test "actionable/2 reaches a mark the reader made before hiding the author", %{
      author: author,
      reader: reader
    } do
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Statuses.bookmark(reader, status)
      {:ok, _} = Relationships.block(author, reader)

      refute Statuses.readable(status.id, reader), "no longer theirs to read"

      assert Statuses.actionable(status.id, reader),
             "but the bookmarks list still returns it, and the button has to work"
    end

    test "actionable/2 is not a way past a block for a post nobody marked", %{
      author: author,
      reader: reader
    } do
      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Relationships.block(author, reader)

      refute Statuses.actionable(status.id, reader)
    end
  end

  describe "the public timeline" do
    test "shows public posts newest first" do
      first = status_fixture()
      second = status_fixture()

      assert [%{id: second_id}, %{id: first_id}] = Statuses.public_timeline()
      assert second_id == second.id
      assert first_id == first.id
    end

    test "leaves out anything not public" do
      for visibility <- ~w(unlisted private direct limited)a do
        status = status_fixture(%{visibility: visibility})

        refute status.id in Enum.map(Statuses.public_timeline(), & &1.id)
      end
    end

    test "leaves out boosts" do
      original = status_fixture()
      {:ok, boost} = Statuses.boost(account_fixture(), original)

      ids = Enum.map(Statuses.public_timeline(), & &1.id)

      assert original.id in ids
      refute boost.id in ids
    end

    test "leaves out a reply to somebody else but keeps a self-reply" do
      author = account_fixture()
      parent = status_fixture(%{account_id: author.id})

      self_reply =
        status_fixture(%{
          account_id: author.id,
          in_reply_to_id: parent.id,
          in_reply_to_account_id: author.id
        })

      other_reply =
        status_fixture(%{
          in_reply_to_id: parent.id,
          in_reply_to_account_id: author.id
        })

      ids = Enum.map(Statuses.public_timeline(), & &1.id)

      assert self_reply.id in ids,
             "a thread by one author is a thread, not a pile of replies"

      refute other_reply.id in ids
    end

    test "can be narrowed to this server" do
      local = status_fixture(%{local: true})
      remote = status_fixture(%{local: false, uri: "https://remote.example/statuses/2"})

      ids = Enum.map(Statuses.public_timeline(local: true), & &1.id)

      assert local.id in ids
      refute remote.id in ids
    end

    test "can be narrowed to a language" do
      german = status_fixture(%{language: "de"})
      english = status_fixture(%{language: "en"})

      ids = Enum.map(Statuses.public_timeline(language: "de"), & &1.id)

      assert german.id in ids
      refute english.id in ids
    end

    test "pages by id, since ids are the cursor" do
      first = status_fixture()
      second = status_fixture()
      third = status_fixture()

      assert [%{id: id}] = Statuses.public_timeline(limit: 1)
      assert id == third.id

      assert Enum.map(Statuses.public_timeline(max_id: third.id), & &1.id) ==
               [second.id, first.id]

      assert Enum.map(Statuses.public_timeline(since_id: first.id), & &1.id) ==
               [third.id, second.id]
    end

    test "refuses to hand out an unbounded page" do
      for _ <- 1..3, do: status_fixture()

      assert length(Statuses.public_timeline(limit: 10_000)) <= 40
    end
  end

  describe "edits" do
    test "snapshot what the status said before" do
      status = status_fixture(%{text: "first draft"})

      assert {:ok, edited} = Statuses.edit_status(status, %{text: "second draft"})
      assert edited.text == "second draft"
      refute is_nil(edited.edited_at)

      assert [%{text: "first draft"}] = Statuses.edit_history(status)
    end

    test "accumulate, oldest first" do
      status = status_fixture(%{text: "one"})
      {:ok, status} = Statuses.edit_status(status, %{text: "two"})
      {:ok, _} = Statuses.edit_status(status, %{text: "three"})

      assert Enum.map(Statuses.edit_history(status), & &1.text) == ["one", "two"]
    end

    test "leave no snapshot behind when the edit itself is rejected" do
      status = status_fixture(%{text: "fine"})

      assert {:error, _} = Statuses.edit_status(status, %{text: String.duplicate("a", 501)})
      assert Statuses.edit_history(status) == []
      assert Repo.get!(Status, status.id).text == "fine"
    end
  end

  describe "mentions" do
    test "address an account and notify by default" do
      status = status_fixture()
      mentioned = account_fixture()

      assert {:ok, mention} = Statuses.mention(status, mentioned)
      refute mention.silent
    end

    test "can be silent, so a long thread stops being a nuisance" do
      status = status_fixture()

      assert {:ok, mention} = Statuses.mention(status, account_fixture(), silent: true)
      assert mention.silent
    end

    test "name an account at most once per status" do
      status = status_fixture()
      mentioned = account_fixture()

      {:ok, _} = Statuses.mention(status, mentioned)

      assert {:error, changeset} = Statuses.mention(status, mentioned)
      assert errors_on(changeset).status_id != []
    end
  end

  describe "tags" do
    test "are stored casefolded but remember how they were written" do
      {:ok, tag} = Statuses.upsert_tag("#Caturday")

      assert tag.name == "caturday"
      assert tag.display_name == "Caturday"
    end

    test "are one tag whatever the spelling" do
      {:ok, first} = Statuses.upsert_tag("Caturday")
      {:ok, second} = Statuses.upsert_tag("#caturday")
      {:ok, third} = Statuses.upsert_tag("CATURDAY")

      assert first.id == second.id
      assert second.id == third.id
    end

    test "refuse a name that no client would linkify" do
      for bad <- ["123", "has space", "with-dash", "", "emoji🎉only"] do
        assert {:error, _} = Statuses.upsert_tag(bad), "accepted #{inspect(bad)}"
      end
    end

    test "accept letters beyond ASCII, since hashtags are not English-only" do
      assert {:ok, tag} = Statuses.upsert_tag("#Grüße")
      assert tag.name == "grüße"
    end

    test "start usable and listable, and unreviewed for trending" do
      # `trendable` is null rather than true until somebody has looked: the
      # trending list is the most prominent place on the server, and a tag
      # nobody has read is not a tag anybody agreed to put there.
      tag = tag_fixture()

      assert tag.usable
      assert tag.listable
      assert tag.trendable == nil
    end

    test "file statuses into a timeline of their own" do
      tag = tag_fixture()
      first = status_fixture()
      second = status_fixture()
      untagged = status_fixture()

      Statuses.tag_status(first, tag)
      Statuses.tag_status(second, tag)

      ids = Enum.map(Statuses.tag_timeline(tag), & &1.id)

      assert ids == [second.id, first.id]
      refute untagged.id in ids
    end

    test "file a status only once, however often it is tagged" do
      tag = tag_fixture()
      status = status_fixture()

      Statuses.tag_status(status, tag)
      Statuses.tag_status(status, tag)

      assert length(Statuses.tag_timeline(tag)) == 1
    end

    test "keep deleted statuses out of their timeline" do
      tag = tag_fixture()
      status = status_fixture()
      Statuses.tag_status(status, tag)
      Statuses.delete_status(status)

      assert Statuses.tag_timeline(tag) == []
    end

    test "normalise/1 answers what a name is stored as" do
      assert Tag.normalise("  #Caturday ") == "caturday"
    end
  end

  describe "favourites and bookmarks" do
    test "are recorded once per account and status" do
      account = account_fixture()
      status = status_fixture()

      assert {:ok, _} = Statuses.favourite(account, status)
      assert {:error, changeset} = Statuses.favourite(account, status)
      assert errors_on(changeset).account_id != []

      assert {:ok, _} = Statuses.bookmark(account, status)
      assert {:error, changeset} = Statuses.bookmark(account, status)
      assert errors_on(changeset).account_id != []
    end

    test "are independent of each other" do
      account = account_fixture()
      status = status_fixture()

      assert {:ok, _} = Statuses.bookmark(account, status)
      assert {:ok, _} = Statuses.favourite(account, status)
    end

    test "go away with the status" do
      account = account_fixture()
      status = status_fixture()
      {:ok, favourite} = Statuses.favourite(account, status)

      Repo.delete!(status)

      assert Repo.get(Abuuba.Statuses.Favourite, favourite.id) == nil
    end
  end

  describe "somebody else's profile" do
    test "does not show their boost of somebody the reader blocked" do
      # Looking at a profile is deliberate, so what that person wrote
      # themselves is shown even to somebody who has blocked them. What they
      # passed along is a different matter: the reader said they would not read
      # that account, and a boost is exactly that account's words.
      reader = account_fixture()
      subject = account_fixture()
      blocked = account_fixture()

      theirs = status_fixture(%{account_id: blocked.id})
      {:ok, _} = Relationships.block(reader, blocked)

      own = status_fixture(%{account_id: subject.id})
      status_fixture(%{account_id: subject.id, reblog_of_id: theirs.id, text: ""})

      ids = subject.id |> Statuses.account_timeline(reader) |> Enum.map(& &1.id)

      # The control: the profile still has its own posts on it.
      assert own.id in ids
      assert length(ids) == 1, "a boost of a blocked account was on the profile"
    end

    test "and still shows what somebody the reader blocked wrote themselves" do
      # Blocking is about what reaches you, not about a page you chose to open.
      reader = account_fixture()
      blocked = account_fixture()

      theirs = status_fixture(%{account_id: blocked.id})
      {:ok, _} = Relationships.block(reader, blocked)

      ids = blocked.id |> Statuses.account_timeline(reader) |> Enum.map(& &1.id)

      assert theirs.id in ids
    end
  end

  describe "account_timeline paging" do
    test "min_id fills the gap from the near end, since_id gives the newest" do
      author = account_fixture()
      first = status_fixture(%{account_id: author.id})
      second = status_fixture(%{account_id: author.id})
      third = status_fixture(%{account_id: author.id})

      assert Enum.map(
               Statuses.account_timeline(author.id, nil, %{min_id: first.id, limit: 1}),
               & &1.id
             ) == [second.id]

      assert Enum.map(
               Statuses.account_timeline(author.id, nil, %{since_id: first.id, limit: 1}),
               & &1.id
             ) == [third.id]
    end
  end

  describe "who-did-what paging" do
    test "favourited_by pages min_id from the near end" do
      status = status_fixture()
      readers = for _ <- 1..3, do: account_fixture()
      for reader <- readers, do: {:ok, _} = Statuses.favourite(reader, status)

      [oldest, middle, _newest] = Enum.sort_by(readers, & &1.id)

      assert Enum.map(
               Statuses.favourited_by(status, %{min_id: oldest.id, limit: 1}),
               & &1.id
             ) == [middle.id]
    end

    test "the favourites list pages min_id by the mark" do
      reader = account_fixture()
      [first, second, third] = for _ <- 1..3, do: status_fixture()
      {:ok, oldest_mark} = Statuses.favourite(reader, first)
      {:ok, _} = Statuses.favourite(reader, second)
      {:ok, _} = Statuses.favourite(reader, third)

      assert Enum.map(
               Statuses.favourites(reader, %{min_id: oldest_mark.id, limit: 1}),
               & &1.status.id
             ) == [second.id]
    end
  end

  describe "get_visible_statuses/2" do
    test "keeps the caller's order and the reader's rules" do
      author = account_fixture()
      reader = account_fixture()
      public = status_fixture(%{account_id: author.id})
      private = status_fixture(%{account_id: author.id, visibility: :private})

      ids = [private.id, public.id]

      assert Enum.map(Statuses.get_visible_statuses(ids, reader), & &1.id) == [public.id]

      {:ok, _} = Relationships.follow(reader, author)

      assert Enum.map(Statuses.get_visible_statuses(ids, reader), & &1.id) ==
               [private.id, public.id]
    end
  end

  describe "counter caches" do
    alias Abuuba.Stats

    test "a post counts towards its author, and a deletion takes it back" do
      author = account_fixture()

      status = status_fixture(%{account_id: author.id})

      assert Stats.account_stats(author).statuses_count == 1
      assert Stats.account_stats(author).last_status_at != nil

      {:ok, _} = Statuses.delete_status(status)

      assert Stats.account_stats(author).statuses_count == 0
    end

    test "deleting the same status twice only counts once, and only tells once" do
      author = account_fixture()
      status = status_fixture(%{account_id: author.id})
      status_id = status.id
      Streaming.subscribe(Streaming.public_topic())

      # Matched on the id: the public topic is shared, and another test's
      # deletion arriving here must not be mistaken for this one.
      {:ok, _} = Statuses.delete_status(status)
      assert_receive {:streaming, "delete", %{id: ^status_id}}

      {:ok, _} = Statuses.delete_status(status)
      refute_receive {:streaming, "delete", %{id: ^status_id}}, 50

      assert Stats.account_stats(author).statuses_count == 0
    end

    test "taking a boost back announces the boost's deletion" do
      original = status_fixture()
      booster = account_fixture()
      {:ok, boost} = Statuses.boost(booster, original)
      Streaming.subscribe(Streaming.public_topic())

      :ok = Statuses.unboost(booster, original)

      # Matched on the id rather than taking whatever arrives first. The public
      # topic is shared, so another test's deletion can land in this mailbox
      # and a positional assertion reads it as the wrong answer.
      boost_id = boost.id
      assert_receive {:streaming, "delete", %{id: ^boost_id}}
    end

    test "a reply counts on its parent, and its deletion takes it back" do
      parent = status_fixture()
      reply = status_fixture(%{in_reply_to_id: parent.id})

      assert Stats.status_stats(parent).replies_count == 1

      {:ok, _} = Statuses.delete_status(reply)

      assert Stats.status_stats(parent).replies_count == 0
    end

    test "a boost counts on the original, and unboosting takes it back" do
      original = status_fixture()
      booster = account_fixture()

      {:ok, _} = Statuses.boost(booster, original)

      assert Stats.status_stats(original).reblogs_count == 1
      assert Stats.account_stats(booster).statuses_count == 1

      :ok = Statuses.unboost(booster, original)

      assert Stats.status_stats(original).reblogs_count == 0
      assert Stats.account_stats(booster).statuses_count == 0
    end

    test "deleting a boost as a status also takes the boost count back" do
      original = status_fixture()
      {:ok, boost} = Statuses.boost(account_fixture(), original)

      {:ok, _} = Statuses.delete_status(boost)

      assert Stats.status_stats(original).reblogs_count == 0
    end

    test "a favourite counts, and unfavouriting takes it back" do
      status = status_fixture()
      reader = account_fixture()

      {:ok, _} = Statuses.favourite(reader, status)

      assert Stats.status_stats(status).favourites_count == 1

      :ok = Statuses.unfavourite(reader, status)

      assert Stats.status_stats(status).favourites_count == 0
    end

    test "a refused double favourite does not count twice" do
      status = status_fixture()
      reader = account_fixture()

      {:ok, _} = Statuses.favourite(reader, status)
      {:error, _} = Statuses.favourite(reader, status)

      assert Stats.status_stats(status).favourites_count == 1
    end

    test "an unfavourite that removed nothing does not move the counter" do
      status = status_fixture()

      :ok = Statuses.unfavourite(account_fixture(), status)

      assert Stats.status_stats(status).favourites_count == 0
    end

    test "a published scheduled post counts, fans out, and can be deleted" do
      author = account_fixture()
      reader = account_fixture()
      {:ok, _} = Relationships.follow(reader, author)

      {:ok, scheduled} =
        Statuses.schedule(
          author,
          %{"text" => "later"},
          DateTime.add(DateTime.utc_now(), 600, :second)
        )

      {:ok, status} = Statuses.publish_scheduled(scheduled)

      assert Stats.account_stats(author).statuses_count == 1
      assert status.id in Feed.status_ids("home", reader.id, %{})

      {:ok, _} = Statuses.delete_status(status)

      assert Stats.account_stats(author).statuses_count == 0
    end

    test "a direct message does not count, coming or going" do
      # The reference implementation leaves direct messages out of the public
      # counters: a stranger reading a profile must not learn how often
      # somebody writes in private.
      author = account_fixture()
      dm = status_fixture(%{account_id: author.id, visibility: :direct})

      assert Stats.account_stats(author).statuses_count == 0
      assert Stats.account_stats(author).last_status_at == nil

      {:ok, _} = Statuses.delete_status(dm)

      assert Stats.account_stats(author).statuses_count == 0
    end

    test "a quiet reply does not count on a public parent" do
      # A followers-only reply to a public post must not tell strangers that
      # replies they cannot read exist.
      parent = status_fixture()
      author = account_fixture()

      reply =
        status_fixture(%{
          account_id: author.id,
          in_reply_to_id: parent.id,
          visibility: :private
        })

      assert Stats.status_stats(parent).replies_count == 0

      {:ok, _} = Statuses.delete_status(reply)

      assert Stats.status_stats(parent).replies_count == 0
    end

    test "deleting an account takes its marks out of the counters" do
      # A hard delete cascades the rows away; the counters they moved have to
      # move back, or every surviving post keeps a phantom favourite.
      away = account_fixture()
      stays = account_fixture()
      post = status_fixture(%{account_id: stays.id})
      {:ok, _} = Statuses.favourite(away, post)
      {:ok, _} = Statuses.boost(away, post)
      status_fixture(%{account_id: away.id, in_reply_to_id: post.id})
      {:ok, _} = Relationships.follow(away, stays)

      assert Stats.status_stats(post).favourites_count == 1
      assert Stats.status_stats(post).reblogs_count == 1
      assert Stats.status_stats(post).replies_count == 1
      assert Stats.account_stats(stays).followers_count == 1

      {:ok, _} = Accounts.delete_account(away)

      assert Stats.status_stats(post).favourites_count == 0
      assert Stats.status_stats(post).reblogs_count == 0
      assert Stats.status_stats(post).replies_count == 0
      assert Stats.account_stats(stays).followers_count == 0
    end

    test "an imported reply counts on its parent but sets no last_status_at" do
      author = account_fixture()
      parent = status_fixture()

      {:ok, _} =
        Statuses.import_status(%{
          id: Snowflake.id_at(~U[2020-01-01 12:00:00Z], 0),
          imported_at: DateTime.utc_now(),
          account_id: author.id,
          text: "from the archive",
          in_reply_to_id: parent.id
        })

      assert Stats.status_stats(parent).replies_count == 1
      assert Stats.account_stats(author).statuses_count == 1
      assert Stats.account_stats(author).last_status_at == nil
    end
  end
end

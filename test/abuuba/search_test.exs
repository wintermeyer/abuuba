defmodule Abuuba.SearchTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Relationships
  alias Abuuba.Search

  describe "reading what somebody typed" do
    test "plain words are the words" do
      assert %{text: "a rainy tuesday", operators: %{}} = Search.parse("a rainy tuesday")
    end

    test "from: names an author and leaves the rest of the query alone" do
      parsed = Search.parse("from:bob about gardening")

      assert parsed.text == "about gardening"
      assert parsed.operators.from == "bob"
    end

    test "the @ in front of a handle is optional, because people type both" do
      assert Search.parse("from:@bob").operators.from == "bob"
      assert Search.parse("from:bob@other.example").operators.from == "bob@other.example"
    end

    test "has: names what a post must carry" do
      # A list, because two of them narrow rather than replace each other.
      assert Search.parse("has:media").operators.has == ["media"]
      assert Search.parse("has:poll").operators.has == ["poll"]
    end

    test "and two of them are both kept" do
      # Collapsing these returned a wider set than was asked for, which is the
      # direction nobody notices.
      assert Search.parse("is:reply is:sensitive").operators.is == ["reply", "sensitive"]
      assert Search.parse("has:media has:poll").operators.has == ["media", "poll"]
    end

    test "and the same one twice is not counted twice" do
      assert Search.parse("is:reply is:reply").operators.is == ["reply"]
    end

    test "but two of an operator that cannot combine keeps the last" do
      # Two authors or two languages are a contradiction rather than a
      # refinement, and last-wins is what the reference implementation does.
      assert Search.parse("from:alice from:bob").operators.from == "bob"
      assert Search.parse("language:de language:en").operators.language == "en"
    end

    test "before: and after: name dates" do
      parsed = Search.parse("before:2026-08-01 after:2026-07-01 holiday")

      assert parsed.operators.before == ~D[2026-08-01]
      assert parsed.operators.after == ~D[2026-07-01]
      assert parsed.text == "holiday"
    end

    test "a date nobody could mean is not an operator" do
      # Left in the words rather than silently ignored: somebody searching for
      # "before:soon" is searching for that text.
      parsed = Search.parse("before:soon")

      assert parsed.operators == %{}
      assert parsed.text == "before:soon"
    end

    test "an operator nobody defined stays part of the words" do
      parsed = Search.parse("colour:blue")

      assert parsed.operators == %{}
      assert parsed.text == "colour:blue"
    end

    test "a bare operator with nothing after it is just text" do
      assert Search.parse("from:").text == "from:"
    end

    test "operators can be the whole query" do
      parsed = Search.parse("from:bob has:media")

      assert parsed.text == ""
      assert parsed.operators.from == "bob"
    end
  end

  describe "searching posts" do
    setup do
      bob = account_fixture(%{username: "bob"})
      carol = account_fixture(%{username: "carol"})

      %{bob: bob, carol: carol}
    end

    test "finds by words", %{bob: bob} do
      status_fixture(%{account_id: bob.id, text: "a post about gardening"})
      status_fixture(%{account_id: bob.id, text: "a post about cooking"})

      assert [found] = Search.statuses("gardening", nil)
      assert found.text =~ "gardening"
    end

    test "but not a post by somebody who blocked the reader", %{bob: bob, carol: carol} do
      # A block means the blocked reader is a stranger to that account, and
      # public posts are exactly what strangers are otherwise given. Every
      # timeline already answers this; search was the surface that did not, so
      # somebody who had been blocked could still read the blocker by typing a
      # word from the post.
      status_fixture(%{account_id: bob.id, text: "gardening in the rain"})
      {:ok, _} = Relationships.block(bob, carol)

      assert Search.statuses("gardening", carol) == []
    end

    test "and not one by somebody the reader blocked", %{bob: bob, carol: carol} do
      status_fixture(%{account_id: bob.id, text: "gardening in the rain"})
      {:ok, _} = Relationships.block(carol, bob)

      assert Search.statuses("gardening", carol) == []
    end

    test "and not one by somebody the reader muted", %{bob: bob, carol: carol} do
      status_fixture(%{account_id: bob.id, text: "gardening in the rain"})
      {:ok, _} = Relationships.mute(carol, bob)

      assert Search.statuses("gardening", carol) == []
    end

    test "and not one from a domain the reader blocked", %{carol: carol} do
      shouty = remote_account_fixture(%{username: "loud", domain: "spam.example"})

      {:ok, _} = Relationships.block_domain(carol, "spam.example")

      status_fixture(%{
        account_id: shouty.id,
        local: false,
        uri: "https://spam.example/s/1",
        text: "gardening in the rain"
      })

      assert Search.statuses("gardening", carol) == []
    end

    test "while an ordinary reader still finds it", %{bob: bob, carol: carol} do
      # The positive control for the three above: without it they would pass
      # just as happily on a search that had stopped answering anybody.
      status_fixture(%{account_id: bob.id, text: "gardening in the rain"})

      assert [found] = Search.statuses("gardening", carol)
      assert found.account_id == bob.id
    end

    test "from: narrows to one author", %{bob: bob, carol: carol} do
      status_fixture(%{account_id: bob.id, text: "gardening notes"})
      status_fixture(%{account_id: carol.id, text: "gardening notes"})

      assert [found] = Search.statuses("from:bob gardening", nil)
      assert found.account_id == bob.id
    end

    test "from: somebody nobody has finds nothing rather than everything", %{bob: bob} do
      # Ignoring an operator that resolves to nobody would answer a narrower
      # question with a wider answer.
      status_fixture(%{account_id: bob.id, text: "gardening notes"})

      assert Search.statuses("from:nobody gardening", nil) == []
    end

    test "has:media narrows to posts that carry something", %{bob: bob} do
      status_fixture(%{account_id: bob.id, text: "plain gardening"})

      with_media =
        status_fixture(%{
          account_id: bob.id,
          text: "gardening in pictures",
          ordered_media_attachment_ids: [1]
        })

      assert [found] = Search.statuses("has:media gardening", nil)
      assert found.id == with_media.id
    end

    test "before: and after: bound when", %{bob: bob} do
      old = status_fixture(%{account_id: bob.id, text: "gardening then"})

      Abuuba.Repo.update_all(from(s in Abuuba.Statuses.Status, where: s.id == ^old.id),
        set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
      )

      status_fixture(%{account_id: bob.id, text: "gardening now"})

      assert [found] = Search.statuses("before:2021-01-01 gardening", nil)
      assert found.id == old.id
    end

    test "keeps a private post away from a stranger", %{bob: bob} do
      status_fixture(%{account_id: bob.id, text: "a quiet gardening note", visibility: :private})

      assert Search.statuses("gardening", nil) == []
    end

    test "operators alone still search", %{bob: bob} do
      status_fixture(%{account_id: bob.id, text: "anything at all"})

      assert [_found] = Search.statuses("from:bob", nil)
    end

    test "an empty query finds nothing rather than everything" do
      assert Search.statuses("", nil) == []
      assert Search.statuses("   ", nil) == []
    end
  end

  describe "what the box can do" do
    test "lists the operators, so the interface can show them" do
      # The UI offers these, and a UI that offers one the parser does not know
      # is a UI that lies.
      names = Enum.map(Search.operators(), & &1.name)

      assert "from:" in names
      assert "has:" in names
      assert "before:" in names
    end
  end

  describe "full text" do
    setup do
      %{viewer: account_fixture(), author: account_fixture()}
    end

    test "matches words rather than fragments", %{viewer: viewer, author: author} do
      # Somebody searching for "garden" is not asking for every post containing
      # those six letters inside a longer word.
      status_fixture(%{account_id: author.id, text: "a post about gardening"})

      assert Search.statuses("gardening", viewer) != []
      assert Search.statuses("garden", viewer) == []
    end

    test "wants all the words", %{viewer: viewer, author: author} do
      wanted = status_fixture(%{account_id: author.id, text: "gardening in the rain"})
      status_fixture(%{account_id: author.id, text: "gardening in the sun"})

      assert [found] = Search.statuses("gardening rain", viewer)
      assert found.id == wanted.id
    end

    test "treats a quoted phrase as one thing", %{viewer: viewer, author: author} do
      wanted = status_fixture(%{account_id: author.id, text: "the quick brown fox"})
      status_fixture(%{account_id: author.id, text: "the brown quick fox"})

      assert [found] = Search.statuses(~s|"quick brown"|, viewer)
      assert found.id == wanted.id
    end

    test "takes a word out when it is prefixed with a minus", %{viewer: viewer, author: author} do
      wanted = status_fixture(%{account_id: author.id, text: "gardening in the rain"})
      status_fixture(%{account_id: author.id, text: "gardening in the sun"})

      assert [found] = Search.statuses("gardening -sun", viewer)
      assert found.id == wanted.id
    end

    test "searches the content warning with the post", %{viewer: viewer, author: author} do
      # It is the only line a reader saw, so a post that cannot be found by it
      # cannot be found by anything they read.
      status =
        status_fixture(%{
          account_id: author.id,
          text: "the details",
          spoiler_text: "about gardening"
        })

      assert [found] = Search.statuses("gardening", viewer)
      assert found.id == status.id
    end

    test "survives punctuation somebody typed", %{viewer: viewer, author: author} do
      status_fixture(%{account_id: author.id, text: "a post about gardening"})

      assert is_list(Search.statuses("gardening & !( ", viewer))
    end
  end

  describe "who may find a post" do
    setup do
      %{viewer: account_fixture(), author: account_fixture()}
    end

    test "its author, whatever its audience", %{author: author} do
      status =
        status_fixture(%{account_id: author.id, text: "gardening quietly", visibility: :private})

      assert [found] = Search.statuses("gardening", author)
      assert found.id == status.id
    end

    test "somebody it mentions", %{viewer: viewer, author: author} do
      status =
        status_fixture(%{account_id: author.id, text: "gardening quietly", visibility: :private})

      {:ok, _} = Abuuba.Statuses.mention(status, viewer)

      assert [found] = Search.statuses("gardening", viewer)
      assert found.id == status.id
    end

    test "somebody who favourited it", %{viewer: viewer, author: author} do
      # Search over your own library is search over what you kept, and a
      # favourite is how somebody keeps a post.
      status =
        status_fixture(%{account_id: author.id, text: "gardening quietly", visibility: :private})

      {:ok, _} = Abuuba.Relationships.follow(viewer, author)
      {:ok, _} = Abuuba.Statuses.favourite(viewer, status)

      assert [found] = Search.statuses("gardening", viewer)
      assert found.id == status.id
    end

    test "somebody who bookmarked it", %{viewer: viewer, author: author} do
      status =
        status_fixture(%{account_id: author.id, text: "gardening quietly", visibility: :private})

      {:ok, _} = Abuuba.Relationships.follow(viewer, author)
      {:ok, _} = Abuuba.Statuses.bookmark(viewer, status)

      assert [found] = Search.statuses("gardening", viewer)
      assert found.id == status.id
    end

    test "and nobody else", %{viewer: viewer, author: author} do
      # Searching must not be a way around who a post was addressed to.
      status_fixture(%{account_id: author.id, text: "gardening quietly", visibility: :private})

      assert Search.statuses("gardening", viewer) == []
    end
  end

  describe "where to look" do
    setup do
      %{viewer: account_fixture(), author: account_fixture()}
    end

    test "in:library is what you wrote or kept", %{viewer: viewer, author: author} do
      # "Where did I see that" is a different question from "who has said this".
      mine = status_fixture(%{account_id: viewer.id, text: "my own gardening note"})
      status_fixture(%{account_id: author.id, text: "somebody else's gardening note"})

      assert [found] = Search.statuses("gardening in:library", viewer)
      assert found.id == mine.id
    end

    test "in:public is everything anybody may read", %{viewer: viewer, author: author} do
      theirs = status_fixture(%{account_id: author.id, text: "somebody else's gardening note"})

      assert theirs.id in Enum.map(Search.statuses("gardening in:public", viewer), & &1.id)
    end
  end

  describe "more operators" do
    setup do
      %{viewer: account_fixture(), author: account_fixture()}
    end

    test "two of them narrow rather than replace each other", %{
      viewer: viewer,
      author: author
    } do
      root = status_fixture(%{account_id: author.id, text: "gardening question"})

      plain_reply =
        status_fixture(%{
          account_id: author.id,
          text: "gardening answer",
          in_reply_to_id: root.id
        })

      sensitive_reply =
        status_fixture(%{
          account_id: author.id,
          text: "gardening secret",
          in_reply_to_id: root.id,
          sensitive: true
        })

      status_fixture(%{account_id: author.id, text: "gardening warning", sensitive: true})

      found = Search.statuses("gardening is:reply is:sensitive", viewer) |> Enum.map(& &1.id)

      assert found == [sensitive_reply.id]
      refute plain_reply.id in found
    end

    test "is:reply and is:sensitive", %{viewer: viewer, author: author} do
      parent = status_fixture(%{account_id: author.id, text: "the first word"})

      reply =
        status_fixture(%{account_id: author.id, text: "gardening", in_reply_to_id: parent.id})

      sensitive = status_fixture(%{account_id: author.id, text: "gardening", sensitive: true})

      assert [^reply] = Search.statuses("gardening is:reply", viewer) |> Enum.map(& &1)
      assert [found] = Search.statuses("gardening is:sensitive", viewer)
      assert found.id == sensitive.id
    end

    test "language: narrows by what it was written in", %{viewer: viewer, author: author} do
      wanted = status_fixture(%{account_id: author.id, text: "gardening", language: "de"})
      status_fixture(%{account_id: author.id, text: "gardening", language: "en"})

      assert [found] = Search.statuses("gardening language:de", viewer)
      assert found.id == wanted.id
    end

    test "during: is one whole day", %{viewer: viewer, author: author} do
      # A date is a day somebody means, not a moment.
      status = status_fixture(%{account_id: author.id, text: "gardening"})
      today = Date.utc_today()

      assert [found] = Search.statuses("gardening during:#{today}", viewer)
      assert found.id == status.id
      assert Search.statuses("gardening during:#{Date.add(today, -1)}", viewer) == []
    end
  end

  describe "accounts" do
    test "are found by username" do
      account = account_fixture(%{username: "gardener"})

      assert account.id in Enum.map(Search.accounts("gardener", nil), & &1.id)
    end

    test "and by display name" do
      account = account_fixture(%{display_name: "The Gardener"})

      assert account.id in Enum.map(Search.accounts("gardener", nil), & &1.id)
    end

    test "and by half a name, which is what autocomplete types" do
      # A tsvector cannot answer half a word, which is why a trigram index sits
      # beside it.
      account = account_fixture(%{username: "gardener"})

      assert account.id in Enum.map(Search.accounts("garde", nil), & &1.id)
    end

    test "but somebody who has moved is not offered" do
      # Their new account is the one worth finding. Offering the old one sends
      # people to an account that will never answer, and it is what the
      # reference implementation drops from search for the same reason.
      #
      # The column is set directly because what is under test is the query, not
      # the migration that writes it.
      arrived = account_fixture(%{username: "gardenernow"})
      departed = account_fixture(%{username: "gardenerwas"})

      {:ok, departed} =
        departed
        |> Ecto.Changeset.change(moved_to_account_id: arrived.id)
        |> Abuuba.Repo.update()

      found = Enum.map(Search.accounts("gardener", nil), & &1.id)

      assert arrived.id in found, "the account somebody moved to must still be findable"
      refute departed.id in found
    end

    test "somebody you follow comes first" do
      # The person somebody means is nearly always somebody they already know.
      viewer = account_fixture()
      stranger = account_fixture(%{username: "gardenerone"})
      known = account_fixture(%{username: "gardenertwo"})
      {:ok, _} = Abuuba.Relationships.follow(viewer, known)

      results = Enum.map(Search.accounts("gardener", viewer), & &1.id)

      assert Enum.find_index(results, &(&1 == known.id)) <
               Enum.find_index(results, &(&1 == stranger.id))
    end

    test "a suspended account is not offered" do
      account = account_fixture(%{username: "gardener"})

      {:ok, _} = Abuuba.Accounts.update_moderation(account, %{suspended_at: DateTime.utc_now()})

      refute account.id in Enum.map(Search.accounts("gardener", nil), & &1.id)
    end

    test "a handle with a domain finds the one on that server" do
      here = account_fixture(%{username: "gardener"})
      there = remote_account_fixture(%{username: "gardener", domain: "other.example"})

      results = Enum.map(Search.accounts("gardener@other.example", nil), & &1.id)

      assert there.id in results
      refute here.id in results
    end
  end

  describe "hashtags" do
    test "an exact match comes first" do
      {:ok, exact} = Abuuba.Statuses.upsert_tag("garden")
      {:ok, longer} = Abuuba.Statuses.upsert_tag("gardening")

      results = Enum.map(Search.tags("garden", nil), & &1.id)

      assert List.first(results) == exact.id
      assert longer.id in results
    end

    test "a tag nobody may list is not offered" do
      {:ok, tag} = Abuuba.Statuses.upsert_tag("quiettag")
      {:ok, _} = tag |> Ecto.Changeset.change(listable: false) |> Abuuba.Repo.update()

      assert Search.tags("quiettag", nil) == []
    end

    test "the leading hash is optional" do
      {:ok, tag} = Abuuba.Statuses.upsert_tag("gardening")

      assert [found] = Search.tags("#gardening", nil)
      assert found.id == tag.id
    end
  end

  describe "the adapter" do
    test "is Postgres unless the server says otherwise" do
      assert Search.adapter() == Abuuba.Search.Postgres
    end

    test "answers every question a call site asks" do
      # The point of the behaviour: call sites ask `Abuuba.Search`, and what
      # answers is configuration rather than a rewrite.
      #
      # Loaded first, because `function_exported?/3` answers false for a module
      # nothing has loaded yet — which made this pass or fail depending on what
      # else the suite had run.
      assert Code.ensure_loaded?(Abuuba.Search.Postgres)

      assert function_exported?(Abuuba.Search.Postgres, :statuses, 3)
      assert function_exported?(Abuuba.Search.Postgres, :accounts, 3)
      assert function_exported?(Abuuba.Search.Postgres, :tags, 3)
    end
  end
end

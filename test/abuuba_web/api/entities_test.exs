defmodule AbuubaWeb.API.EntitiesTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Statuses
  alias AbuubaWeb.API.Entities

  setup do
    author = account_fixture(%{username: "alice"})

    %{author: author, status: status_fixture(%{account_id: author.id, text: "hello"})}
  end

  describe "a status" do
    test "carries what a client renders", %{status: status, author: author} do
      rendered = Entities.status(status)

      assert rendered["content"] == "<p>hello</p>"
      assert rendered["visibility"] == "public"
      assert rendered["account"]["username"] == author.username
      assert rendered["created_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "gives every id as a string", %{status: status} do
      rendered = Entities.status(status)

      assert rendered["id"] == to_string(status.id)
      assert rendered["account"]["id"] == to_string(status.account_id)
    end

    test "counts replies, boosts and favourites", %{status: status, author: author} do
      reader = account_fixture()
      status_fixture(%{account_id: author.id, in_reply_to_id: status.id})
      {:ok, _} = Statuses.boost(reader, status)
      {:ok, _} = Statuses.favourite(reader, status)

      rendered = Entities.status(status)

      assert rendered["replies_count"] == 1
      assert rendered["reblogs_count"] == 1
      assert rendered["favourites_count"] == 1
    end

    test "counts only the replies everybody can see", %{status: status, author: author} do
      # `replies_count` reads the counter cache, and the cache is only moved by
      # public and unlisted replies — a private or direct reply to a post must
      # not tell the world it exists by making the number go up. Mastodon
      # counts the same way (`distributable?` in its `Status` model).
      status_fixture(%{account_id: author.id, in_reply_to_id: status.id})
      status_fixture(%{account_id: author.id, in_reply_to_id: status.id, visibility: :unlisted})
      status_fixture(%{account_id: author.id, in_reply_to_id: status.id, visibility: :private})
      status_fixture(%{account_id: author.id, in_reply_to_id: status.id, visibility: :direct})

      assert Entities.status(status)["replies_count"] == 2
    end

    test "says nothing about a reader who is not there", %{status: status} do
      # Absent rather than false: a client caching the anonymous answer must
      # not then believe the reader has favourited nothing.
      rendered = Entities.status(status)

      refute Map.has_key?(rendered, "favourited")
      refute Map.has_key?(rendered, "bookmarked")
    end

    test "answers a reader about their own relationship to it", %{status: status} do
      reader = account_fixture()
      {:ok, _} = Statuses.favourite(reader, status)
      {:ok, _} = Statuses.bookmark(reader, status)

      rendered = Entities.status(status, reader)

      assert rendered["favourited"]
      assert rendered["bookmarked"]
      refute rendered["reblogged"]
    end

    test "does not leak one reader's marks to another", %{status: status} do
      one = account_fixture()
      {:ok, _} = Statuses.bookmark(one, status)

      refute Entities.status(status, account_fixture())["bookmarked"]
    end

    test "names everybody it mentions", %{status: status} do
      bob = remote_account_fixture(%{username: "bob", domain: "remote.example"})
      {:ok, _} = Statuses.mention(status, bob)

      assert [%{"acct" => "bob@remote.example"}] = Entities.status(status)["mentions"]
    end

    test "names its hashtags with a link", %{status: status} do
      tag = tag_fixture("Caturday")
      :ok = Statuses.tag_status(status, tag)

      assert [%{"name" => "caturday", "url" => url}] = Entities.status(status)["tags"]
      assert url =~ "/tags/caturday"
    end
  end

  describe "a boost" do
    test "carries the post it points at and no words of its own", %{status: status} do
      booster = account_fixture()
      {:ok, boost} = Statuses.boost(booster, status)

      rendered = Entities.status(boost, booster)

      assert rendered["content"] == ""
      assert rendered["reblog"]["id"] == to_string(status.id)
      assert rendered["reblog"]["content"] == "<p>hello</p>"
    end

    test "shows nothing where the reader may not see the original", %{author: author} do
      private = status_fixture(%{account_id: author.id, visibility: :private})
      {:ok, boost} = Statuses.boost(author, private)

      assert Entities.status(boost, account_fixture())["reblog"] == nil
    end
  end

  describe "an account" do
    test "counts their posts and says when the last one was", %{author: author} do
      rendered = Entities.account(author)

      assert rendered["statuses_count"] == 1
      assert rendered["last_status_at"] == Date.to_iso8601(Date.utc_today())
    end

    test "reports no last post for an account that never posted" do
      rendered = Entities.account(account_fixture())

      assert rendered["statuses_count"] == 0
      assert rendered["last_status_at"] == nil
    end

    test "uses a bare username locally and a full handle for a stranger" do
      # The asymmetry is what every client renders, and it is how a reader
      # tells at a glance which posts came from elsewhere.
      local = account_fixture(%{username: "carol"})
      remote = remote_account_fixture(%{username: "bob", domain: "remote.example"})

      assert Entities.account(local)["acct"] == "carol"
      assert Entities.account(remote)["acct"] == "bob@remote.example"
    end

    test "is nothing when there is no account" do
      assert Entities.account(nil) == nil
    end

    test "reports its counters" do
      author = account_fixture()
      follower = account_fixture()
      {:ok, _} = Abuuba.Relationships.follow(follower, author)

      assert Entities.account(author)["followers_count"] == 1
    end
  end

  describe "a poll" do
    setup %{status: status} do
      {:ok, poll} = Statuses.create_poll(status, %{options: ["yes", "no"]})

      %{poll: poll}
    end

    test "carries each option with its tally", %{poll: poll} do
      voter = account_fixture()
      {:ok, poll} = Statuses.vote(poll, voter, [0])

      rendered = Entities.poll(poll)

      assert rendered["options"] == [
               %{"title" => "yes", "votes_count" => 1},
               %{"title" => "no", "votes_count" => 0}
             ]

      assert rendered["votes_count"] == 1
      assert rendered["voters_count"] == 1
    end

    test "tells a reader how they voted and nobody how anybody else did", %{poll: poll} do
      # Reporting somebody else's choices would publish how a person voted,
      # which is not what they agreed to when they answered.
      voter = account_fixture()
      {:ok, poll} = Statuses.vote(poll, voter, [1])

      assert Entities.poll(poll, voter)["own_votes"] == [1]
      assert Entities.poll(poll, voter)["voted"]

      other = account_fixture()

      assert Entities.poll(poll, other)["own_votes"] == []
      refute Entities.poll(poll, other)["voted"]
    end

    test "says nothing about voting to nobody in particular", %{poll: poll} do
      assert Entities.poll(poll)["own_votes"] == []
      refute Entities.poll(poll)["voted"]
    end

    test "rides along on the status it belongs to", %{status: status} do
      assert Entities.status(status)["poll"]["options"] != []
    end
  end

  describe "the source of a post" do
    test "is the text as it was typed, not as it renders", %{author: author} do
      status =
        status_fixture(%{account_id: author.id, text: "raw text", spoiler_text: "warning"})

      assert Entities.status_source(status) == %{
               "id" => to_string(status.id),
               "text" => "raw text",
               "spoiler_text" => "warning"
             }
    end
  end

  describe "a thread" do
    test "renders both halves", %{status: status, author: author} do
      reply = status_fixture(%{account_id: author.id, in_reply_to_id: status.id})

      rendered = status |> Statuses.context(author) |> Entities.context(author)

      assert rendered["ancestors"] == []
      assert [%{"id" => id}] = rendered["descendants"]
      assert id == to_string(reply.id)
    end
  end

  # The budgets below went up by exactly one when the status entity gained its
  # `quote`: the page's quotes are gathered in a single query alongside its
  # media, cards and counters. One more is the right answer for one more field;
  # anything larger means somebody has asked per post again.
  describe "rendering a page of them" do
    test "costs about the same for twenty as for one", %{author: author} do
      # A timeline renders twenty at a time. Rendering each on its own is
      # roughly eight queries a post, which is a hundred and sixty per request
      # to answer what a handful of batched queries already know.
      one = for _ <- 1..1, do: status_fixture(%{account_id: author.id})
      many = for _ <- 1..20, do: status_fixture(%{account_id: author.id})

      reader = account_fixture()

      small = count_queries(fn -> Entities.statuses(one, reader) end)
      large = count_queries(fn -> Entities.statuses(many, reader) end)

      assert large <= small + 2,
             "rendering 20 took #{large} queries against #{small} for one"
    end

    test "renders the same thing as one at a time", %{status: status} do
      reader = account_fixture()
      {:ok, _} = Statuses.favourite(reader, status)

      assert Entities.statuses([status], reader) == [Entities.status(status, reader)]
    end

    # The test above only says twenty costs no more than one, which a page
    # costing forty queries would also satisfy. These put a number on it.
    #
    # It is worth a number because the round trips, not the rows, are what a
    # timeline read spends its time on: a page of twenty plain posts was
    # seventeen separate queries against a database that answered each of them
    # in well under a millisecond. Raise a budget deliberately if a feature
    # really needs another query, and never by "just one more" twice.
    #
    # Per page shape, because the shapes cost different amounts and a budget
    # written against the cheapest one is a budget that never fails. A real
    # home timeline is mostly boosts, so a plain-text page on its own would
    # have left the common case unguarded.
    #
    # Each of these went up by one when every post gained a conversation
    # (#221). The lookup for muted threads had been short-circuiting on a page
    # where every `conversation_id` was nil, which was every page, so the old
    # numbers were measuring a feature that did not work. It is one query for
    # the page however long the page is — measured at 5, 20 and 40 posts, all
    # ten — so this is one more round trip, not one per post.
    test "a page of plain posts stays within its query budget", %{author: author} do
      page = for _ <- 1..20, do: status_fixture(%{account_id: author.id})
      reader = account_fixture()

      count = count_queries(fn -> Entities.statuses(page, reader) end)

      assert count <= 10, "a page of twenty plain posts took #{count} queries"
    end

    test "posts written in an app cost one query for the whole page", %{author: author} do
      # A real timeline is one or two apps over and over. Asking per post would
      # be twenty questions with two answers between them.
      {:ok, application, _secret} =
        Abuuba.OAuth.create_application(%{
          name: "Ivory",
          redirect_uris: "urn:ietf:wg:oauth:2.0:oob"
        })

      page =
        for _ <- 1..20,
            do: status_fixture(%{account_id: author.id, application_id: application.id})

      reader = account_fixture()

      count = count_queries(fn -> Entities.statuses(page, reader) end)

      assert count <= 11, "a page of twenty posts from one app took #{count} queries"
      assert [%{"application" => %{"name" => "Ivory"}} | _] = Entities.statuses(page, reader)
    end

    test "a page nobody is signed in for is cheaper still", %{author: author} do
      # No reader means the four "have I favourited this" questions cannot have
      # an answer, so they must not be asked. Every crawler and link preview
      # takes this path.
      page = for _ <- 1..20, do: status_fixture(%{account_id: author.id})

      count = count_queries(fn -> Entities.statuses(page, nil) end)

      assert count <= 8, "an anonymous page of twenty took #{count} queries"
    end

    test "a page of boosts stays within its query budget", %{author: author} do
      # Boosts cost one more than plain posts: the originals have to be loaded
      # before anything can be rendered from them.
      booster = account_fixture()
      originals = for _ <- 1..20, do: status_fixture(%{account_id: author.id})
      page = Enum.map(originals, fn original -> elem(Statuses.boost(booster, original), 1) end)
      reader = account_fixture()

      count = count_queries(fn -> Entities.statuses(page, reader) end)

      assert count <= 11, "a page of twenty boosts took #{count} queries"
    end

    test "a page rendered for a context costs one query for the filters", %{author: author} do
      # The reader's rules do not change between the first post on a page and
      # the twentieth, so asking for them per post is nineteen questions with
      # the same answer.
      reader = account_fixture()

      {:ok, _filter} =
        Abuuba.Filters.create(reader, %{
          title: "No spoilers",
          context: ["home"],
          filter_action: "warn",
          keywords_attributes: [%{keyword: "ending", whole_word: true}]
        })

      page = for _ <- 1..20, do: status_fixture(%{account_id: author.id})

      count = count_queries(fn -> Entities.statuses(page, reader, filter_context: "home") end)

      assert count <= 11, "a page of twenty took #{count} queries with filters on"
    end

    test "still says which filters matched", %{author: author} do
      reader = account_fixture()

      {:ok, _filter} =
        Abuuba.Filters.create(reader, %{
          title: "No spoilers",
          context: ["home"],
          filter_action: "warn",
          keywords_attributes: [%{keyword: "ending", whole_word: true}]
        })

      spoiler = status_fixture(%{account_id: author.id, text: "the ending was good"})
      plain = status_fixture(%{account_id: author.id, text: "nothing in particular"})

      # The positive control for the budget test above: a page that costs one
      # query and answers nothing would pass it and be useless.
      [rendered_spoiler, rendered_plain] =
        Entities.statuses([spoiler, plain], reader, filter_context: "home")

      assert [%{"filter" => %{"title" => "No spoilers"}}] = rendered_spoiler["filtered"]
      assert rendered_plain["filtered"] == []
    end

    test "a notifications filter reaches a client, not only the web page", %{author: author} do
      # The web notifications page passes its context and the API entity
      # passed none, and no context means no filters are even loaded. So a
      # filter set to apply to notifications did nothing at all for anybody
      # reading this server through an app, which is most people.
      reader = account_fixture()

      {:ok, _filter} =
        Abuuba.Filters.create(reader, %{
          title: "No spoilers",
          context: ["notifications"],
          filter_action: "warn",
          keywords_attributes: [%{keyword: "ending", whole_word: true}]
        })

      spoiler = status_fixture(%{account_id: author.id, text: "the ending was good"})

      {:ok, notification} =
        Abuuba.Notifications.notify(reader, author, "mention", status_id: spoiler.id)

      [rendered] = Entities.notifications([notification], reader)

      assert [%{"filter" => %{"title" => "No spoilers"}}] = rendered["status"]["filtered"]
    end

    test "answers the same for one post as for a page", %{author: author} do
      reader = account_fixture()

      {:ok, _filter} =
        Abuuba.Filters.create(reader, %{
          title: "No spoilers",
          context: ["home"],
          filter_action: "warn",
          keywords_attributes: [%{keyword: "ending", whole_word: true}]
        })

      status = status_fixture(%{account_id: author.id, text: "the ending was good"})

      assert Entities.statuses([status], reader, filter_context: "home") ==
               [Entities.status(status, reader, filter_context: "home")]
    end
  end

  describe "a page of notifications" do
    test "stays within its query budget", %{author: author, status: status} do
      for _ <- 1..8 do
        fan = account_fixture()
        {:ok, _} = Statuses.favourite(fan, status)
        Abuuba.Notifications.notify(author, fan, "favourite", status_id: status.id)
      end

      notifications = Abuuba.Notifications.list(author, %{limit: 40})
      assert length(notifications) == 8

      count = count_queries(fn -> Entities.notifications(notifications, author) end)

      # One for the senders, one for the statuses, and the fixed per-page set
      # the status render itself needs — regardless of the eight rows.
      assert count <= 14, "a page of eight notifications took #{count} queries"

      [rendered | _] = Entities.notifications(notifications, author)

      assert rendered["type"] == "favourite"
      assert rendered["account"]["id"]
      assert rendered["status"]["id"] == to_string(status.id)
    end
  end

  defp count_queries(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "count-#{inspect(ref)}",
      [:abuuba, :repo, :query],
      # Only this process's queries. The handler is global and runs in whichever
      # process ran the query, so without this an async test elsewhere lands in
      # the count and the assertion fails for a seed rather than for a change.
      fn _event, _measurements, _metadata, _config ->
        if self() == parent, do: send(parent, {ref, :query})
      end,
      nil
    )

    fun.()

    :telemetry.detach("count-#{inspect(ref)}")

    drain(ref, 0)
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end
end

defmodule Abuuba.Importer.GraphTest do
  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts.Account
  alias Abuuba.Collections.Collection
  alias Abuuba.Collections.Item, as: CollectionItem
  alias Abuuba.EmailSubscriptions.Subscription
  alias Abuuba.Filters.Filter
  alias Abuuba.Filters.Keyword, as: FilterKeyword
  alias Abuuba.Importer.Graph
  alias Abuuba.Lists.List, as: UserList
  alias Abuuba.MastodonSource, as: Source
  alias Abuuba.Moderation.Severance
  alias Abuuba.Moderation.SeveranceEvent
  alias Abuuba.Notifications.Notification
  alias Abuuba.Notifications.Policy
  alias Abuuba.Relationships.Block
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.Mute
  alias Abuuba.Repo
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Timelines.Marker

  @now ~N[2026-01-01 00:00:00]

  setup do
    Source.create!()
    seed_target!()
    seed_source!()

    on_exit(&Source.drop!/0)

    :ok
  end

  defp opts, do: [repo: Repo, prefix: Source.prefix()]

  describe "the follow graph" do
    test "follows keep the URI a peer's undo will name" do
      :ok = Graph.run(opts())

      follow = Repo.get(Follow, 100)

      assert follow.account_id == 2
      assert follow.target_account_id == 1
      assert follow.uri == "https://other.example/follows/100"
    end

    test "and the three things somebody chose about them" do
      :ok = Graph.run(opts())

      follow = Repo.get(Follow, 101)

      refute follow.show_reblogs
      assert follow.notify
      assert follow.languages == ["de"]
    end

    test "blocks and mutes come across, because nobody would notice them going" do
      :ok = Graph.run(opts())

      assert %Block{target_account_id: 2} = Repo.get(Block, 200)
      assert %Mute{hide_notifications: true} = Repo.get(Mute, 300)
    end

    test "run twice without doubling anything" do
      :ok = Graph.run(opts())
      :ok = Graph.run(opts())

      assert Repo.aggregate(Follow, :count) == 2
    end
  end

  describe "what people set for themselves" do
    test "lists keep their membership" do
      :ok = Graph.run(opts())

      assert %UserList{title: "Friends", replies_policy: "list"} = Repo.get(UserList, 400)

      assert [[400, 2]] =
               Repo.query!("SELECT list_id, account_id FROM list_accounts").rows
    end

    test "collections keep what somebody curated" do
      # A collection is a list of people its author put together by hand. There
      # is nowhere to recover one from, so losing it in a migration means the
      # work is simply gone.
      :ok = Graph.run(opts())

      collection = Repo.get(Collection, 800)

      assert collection.name == "People who write about bees"
      assert collection.account_id == 1
      assert collection.description == "A short list."
      assert collection.language == "en"
      assert collection.discoverable
    end

    test "and a member keeps their place in it" do
      :ok = Graph.run(opts())

      assert %CollectionItem{account_id: 2, position: 3, state: "accepted"} =
               Repo.get(CollectionItem, 810)
    end

    test "somebody who took themselves out stays out" do
      # The source counts the states and abuuba names them. Reading the number as
      # the wrong word would put a person back on a list they had left, which
      # is the one mistake here nobody would forgive.
      :ok = Graph.run(opts())

      assert %CollectionItem{state: "revoked"} = Repo.get(CollectionItem, 811)
    end

    test "an email subscription keeps the address and the language it wanted" do
      # Whoever subscribed to an author by mail simply stops hearing from them
      # otherwise, and nothing tells either side.
      :ok = Graph.run(opts())

      assert %Subscription{email: "reader@example.com", locale: "de", account_id: 1} =
               subscription = Repo.get(Subscription, 820)

      assert subscription.confirmed_at
    end

    test "a severance keeps which way round it went" do
      # The number means the opposite of what its position in abuuba's own list
      # would suggest: `passive` is 0 there and second here. Getting it wrong
      # tells somebody they lost people they followed when what they lost was
      # followers.
      :ok = Graph.run(opts())

      assert %SeveranceEvent{type: "domain_block", target_name: "gone.example"} =
               Repo.get(SeveranceEvent, 830)

      assert %Severance{direction: "passive", local_account_id: 1, remote_account_id: 2} =
               Repo.get(Severance, 840)
    end

    test "a filter keeps its phrase, its keywords and what it does" do
      :ok = Graph.run(opts())

      filter = Repo.get(Filter, 500)

      assert filter.title == "spoilers"
      assert filter.filter_action == "hide"
      assert filter.context == ["home"]
      assert %FilterKeyword{keyword: "ending"} = Repo.get(FilterKeyword, 510)
    end

    test "read markers move from the user to the account" do
      :ok = Graph.run(opts())

      marker = Repo.get_by(Marker, account_id: 1, timeline: "home")

      assert marker.last_read_id == 10
    end

    test "a scheduled post keeps its time and lifts its media out of the params" do
      :ok = Graph.run(opts())

      scheduled = Repo.get(ScheduledStatus, 600)

      assert scheduled.params["text"] == "later"
      assert scheduled.media_attachment_ids == [600]
    end
  end

  describe "notification policies" do
    test "come across as the three answers this server gives, not as a yes or no" do
      # accept, filter, drop. Collapsing them to a boolean would either lose
      # the difference between filtering and dropping or write a boolean into
      # a column that holds a word, which takes the whole step down.
      :ok = Graph.run(opts())

      policy = Repo.get(Policy, 1)

      assert policy.for_not_following == "filter"
      assert policy.for_new_accounts == "drop"
      assert policy.for_bots == "accept"
    end
  end

  describe "notifications" do
    test "keep what caused them" do
      :ok = Graph.run(opts())

      assert %Notification{type: "favourite", status_id: 10} = Repo.get(Notification, 700)
    end

    test "keep the ones whose cause is gone, without the cause" do
      # "Somebody followed you" is still true when there is no status, and so
      # is a favourite of a post that has since been deleted.
      :ok = Graph.run(opts())

      assert %Notification{type: "follow", status_id: nil} = Repo.get(Notification, 701)
    end

    test "a kind this server cannot render is not carried into somebody's list" do
      :ok = Graph.run(opts())

      assert is_nil(Repo.get(Notification, 702))
    end

    test "get a group of their own when the source never grouped them" do
      :ok = Graph.run(opts())

      assert Repo.get(Notification, 701).group_key =~ "701"
    end
  end

  describe "verification" do
    test "compares the follower digest peers will ask for" do
      :ok = Graph.run(opts())

      assert [%{name: "follower digests", checked: 1, failures: []}] = Graph.verify(opts())
    end

    test "and names the account whose followers did not all come across" do
      # A digest that does not match is a peer that will keep asking, so the
      # check has to notice before the peer does.
      :ok = Graph.run(opts())

      Repo.delete_all(from(f in Follow, where: f.id == 100))

      assert [%{failures: [%{id: 1, domain: "other.example"}]}] = Graph.verify(opts())
    end
  end

  ## Fixtures

  defp seed_target! do
    Repo.insert_all(Account, [
      %{
        id: 1,
        username: "alice",
        uri: "https://here.example/users/alice",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: 2,
        username: "bob",
        domain: "other.example",
        uri: "https://other.example/users/bob",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    Repo.insert_all("conversations", [
      %{id: 900, inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}
    ])

    Repo.insert_all("statuses", [
      %{
        id: 10,
        account_id: 1,
        text: "",
        spoiler_text: "",
        visibility: "public",
        quote_policy: "public",
        local: true,
        sensitive: false,
        ordered_media_attachment_ids: [],
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])
  end

  defp seed_source! do
    for id <- [1, 2] do
      Source.insert!("accounts", %{
        "id" => id,
        "username" => if(id == 1, do: "alice", else: "bob"),
        "domain" => if(id == 2, do: "other.example"),
        "uri" =>
          if(id == 1,
            do: "https://here.example/users/alice",
            else: "https://other.example/users/bob"
          ),
        "created_at" => @now,
        "updated_at" => @now
      })
    end

    Source.insert!("users", %{
      "id" => 30,
      "account_id" => 1,
      "email" => "alice@example.com",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("statuses", %{
      "id" => 10,
      "account_id" => 1,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("conversations", %{"id" => 900, "created_at" => @now, "updated_at" => @now})

    Source.insert!("follows", %{
      "id" => 100,
      "account_id" => 2,
      "target_account_id" => 1,
      "uri" => "https://other.example/follows/100",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("follows", %{
      "id" => 101,
      "account_id" => 1,
      "target_account_id" => 2,
      "show_reblogs" => false,
      "notify" => true,
      "languages" => ["de"],
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("blocks", %{
      "id" => 200,
      "account_id" => 1,
      "target_account_id" => 2,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("mutes", %{
      "id" => 300,
      "account_id" => 1,
      "target_account_id" => 2,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("collections", %{
      "id" => 800,
      "account_id" => 1,
      "name" => "People who write about bees",
      "description" => "A short list.",
      "discoverable" => true,
      "sensitive" => false,
      "local" => true,
      "language" => "en",
      "item_count" => 1,
      "created_at" => @now,
      "updated_at" => @now
    })

    # accepted (1) over there, and the word "accepted" here.
    Source.insert!("collection_items", %{
      "id" => 810,
      "collection_id" => 800,
      "account_id" => 2,
      "position" => 3,
      "state" => 1,
      "created_at" => @now,
      "updated_at" => @now
    })

    # revoked (3): somebody took themselves back out, and that has to survive
    # or they are quietly re-added to a list they left.
    Source.insert!("collection_items", %{
      "id" => 811,
      "collection_id" => 800,
      "account_id" => 1,
      "position" => 1,
      "state" => 3,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("email_subscriptions", %{
      "id" => 820,
      "account_id" => 1,
      "email" => "reader@example.com",
      "locale" => "de",
      "confirmation_token" => "tok-abc",
      "confirmed_at" => @now,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("relationship_severance_events", %{
      "id" => 830,
      "type" => 0,
      "target_name" => "gone.example",
      "purged" => false,
      "created_at" => @now,
      "updated_at" => @now
    })

    # passive is 0 over there and the second word in abuuba's own list, so
    # reading the number as a position would say the opposite of what happened.
    Source.insert!("severed_relationships", %{
      "id" => 840,
      "relationship_severance_event_id" => 830,
      "local_account_id" => 1,
      "remote_account_id" => 2,
      "direction" => 0,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("lists", %{
      "id" => 400,
      "account_id" => 1,
      "title" => "Friends",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("list_accounts", %{"id" => 410, "list_id" => 400, "account_id" => 2})

    Source.insert!("custom_filters", %{
      "id" => 500,
      "account_id" => 1,
      "phrase" => "spoilers",
      "context" => ["home"],
      "action" => 1,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("custom_filter_keywords", %{
      "id" => 510,
      "custom_filter_id" => 500,
      "keyword" => "ending",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("markers", %{
      "id" => 550,
      "user_id" => 30,
      "timeline" => "home",
      "last_read_id" => 10,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("scheduled_statuses", %{
      "id" => 600,
      "account_id" => 1,
      "scheduled_at" => ~N[2026-06-01 00:00:00],
      "params" => %{"text" => "later", "media_ids" => ["600"]}
    })

    Source.insert!("favourites", %{
      "id" => 650,
      "account_id" => 2,
      "status_id" => 10,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("notifications", %{
      "id" => 700,
      "account_id" => 1,
      "from_account_id" => 2,
      "activity_id" => 650,
      "activity_type" => "Favourite",
      "type" => "favourite",
      "group_key" => "fav-10",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("notification_policies", %{
      "id" => 1,
      "account_id" => 1,
      "for_not_following" => 1,
      "for_new_accounts" => 2,
      "for_bots" => 0,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("notifications", %{
      "id" => 702,
      "account_id" => 1,
      "from_account_id" => 2,
      "activity_id" => 1,
      "activity_type" => "Whatever",
      "type" => "something_new",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("notifications", %{
      "id" => 701,
      "account_id" => 1,
      "from_account_id" => 2,
      "activity_id" => 100,
      "activity_type" => "Follow",
      "type" => "follow",
      "created_at" => @now,
      "updated_at" => @now
    })
  end
end

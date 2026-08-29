defmodule AbuubaWeb.API.NotificationControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Notifications
  alias Abuuba.OAuth
  alias Abuuba.Statuses

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      anon: build_conn(),
      account: account
    }
  end

  describe "a mention in a direct message" do
    test "is held back from the main list, and is in the filtered one", %{
      conn: conn,
      account: account
    } do
      # Mastodon's default and ours: a private mention from somebody you do
      # not follow goes to the requests inbox rather than the main list, so
      # a stranger cannot put a message in front of you by addressing it.
      # It is held, not dropped -- the difference matters to whoever was
      # written to.
      sender = account_fixture(%{username: "bob"})

      status =
        status_fixture(%{
          account_id: sender.id,
          text: "a word meant for one person",
          visibility: :direct
        })

      {:ok, _mention} = Statuses.mention(status, account)

      main = conn |> get("/api/v1/notifications") |> json_response(200)

      assert Enum.filter(main, &(&1["type"] == "mention")) == []

      assert [held] = Notifications.list(account, %{filtered: true})
      assert held.type == "mention"
      assert held.status_id == status.id
    end

    test "and reaches the main list when they follow each other", %{
      conn: conn,
      account: account
    } do
      # The positive control. Without it the test above passes just as
      # happily on a server that lost the notification altogether.
      sender = account_fixture(%{username: "carol"})
      {:ok, _follow} = Abuuba.Relationships.follow(account, sender)

      status =
        status_fixture(%{
          account_id: sender.id,
          text: "from somebody you follow",
          visibility: :direct
        })

      {:ok, _mention} = Statuses.mention(status, account)

      body = conn |> get("/api/v1/notifications") |> json_response(200)

      assert [notification] = Enum.filter(body, &(&1["type"] == "mention"))
      assert notification["status"]["visibility"] == "direct"
    end
  end

  describe "the flat list" do
    setup %{account: account} do
      sender = account_fixture()
      {:ok, notification} = Notifications.notify(account, sender, "follow")

      %{notification: notification, sender: sender}
    end

    test "carries what happened and who did it", %{
      conn: conn,
      notification: notification,
      sender: sender
    } do
      assert [entry] = json_response(get(conn, "/api/v1/notifications"), 200)

      assert entry["id"] == to_string(notification.id)
      assert entry["type"] == "follow"
      assert entry["account"]["id"] == to_string(sender.id)
    end

    test "needs a token", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/notifications"), 422)["error"]
    end

    test "one on its own", %{conn: conn, notification: notification} do
      body = json_response(get(conn, "/api/v1/notifications/#{notification.id}"), 200)

      assert body["type"] == "follow"
    end

    test "somebody else's is simply not there", %{conn: conn} do
      other = account_fixture()
      {:ok, theirs} = Notifications.notify(other, account_fixture(), "follow")

      assert json_response(get(conn, "/api/v1/notifications/#{theirs.id}"), 404)["error"]
    end

    test "narrowing by type", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id})
      Notifications.notify(account, account_fixture(), "reblog", status_id: status.id)

      body = json_response(get(conn, "/api/v1/notifications", %{"types" => ["reblog"]}), 200)

      assert Enum.map(body, & &1["type"]) == ["reblog"]

      # `types[0]=reblog` is a map keyed by the index by the time it arrives,
      # and reading only the list narrowed by nothing -- a client asking for
      # one kind got the lot, which looks like the filter is simply ignored.
      numbered =
        json_response(get(conn, "/api/v1/notifications", %{"types" => %{"0" => "reblog"}}), 200)

      assert Enum.map(numbered, & &1["type"]) == ["reblog"]
    end

    test "the unread count", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/notifications/unread_count"), 200)["count"] == 1
    end

    test "dismissing one", %{conn: conn, notification: notification, account: account} do
      assert json_response(post(conn, "/api/v1/notifications/#{notification.id}/dismiss"), 200)
      assert Notifications.list(account) == []
    end

    test "clearing all", %{conn: conn, account: account} do
      assert json_response(post(conn, "/api/v1/notifications/clear"), 200)
      assert Notifications.list(account) == []
    end
  end

  describe "the grouped list" do
    test "puts everybody boosting one post on one line", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id})

      for _ <- 1..3 do
        Notifications.notify(account, account_fixture(), "reblog", status_id: status.id)
      end

      body = json_response(get(conn, "/api/v2/notifications"), 200)

      assert [group] = body["notification_groups"]
      assert group["notifications_count"] == 3
      assert group["type"] == "reblog"
      assert length(body["accounts"]) == 3
    end

    test "carries the statuses alongside rather than inside", %{conn: conn, account: account} do
      # A grouped response names ids and carries the objects once, so twenty
      # boosts of one post do not carry twenty copies of it.
      status = status_fixture(%{account_id: account.id})
      Notifications.notify(account, account_fixture(), "reblog", status_id: status.id)

      body = json_response(get(conn, "/api/v2/notifications"), 200)

      assert [%{"id" => id}] = body["statuses"]
      assert id == to_string(status.id)
    end

    test "answers a type the client cannot group as its own entries", %{
      conn: conn,
      account: account
    } do
      # A client written before a type existed shows it as a plain entry
      # rather than dropping it or crashing on a shape it cannot read.
      for _ <- 1..2, do: Notifications.notify(account, account_fixture(), "follow")

      body =
        json_response(get(conn, "/api/v2/notifications", %{"grouped_types" => ["reblog"]}), 200)

      assert length(body["notification_groups"]) == 2
    end

    test "one group on its own, in the same envelope as the list", %{
      conn: conn,
      account: account
    } do
      status = status_fixture(%{account_id: account.id})

      {:ok, notification} =
        Notifications.notify(account, account_fixture(), "reblog", status_id: status.id)

      body = json_response(get(conn, "/api/v2/notifications/#{notification.group_key}"), 200)

      # A client reusing its list parser has to find the accounts and statuses
      # it needs to render the group with.
      assert [group] = body["notification_groups"]
      assert group["type"] == "reblog"
      assert [_account] = body["accounts"]
      assert [_status] = body["statuses"]
    end

    test "a group key nobody has is a plain miss", %{conn: conn} do
      assert json_response(get(conn, "/api/v2/notifications/nothing-like-it"), 404)
    end

    test "dismissing a group takes the whole line away", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id})

      {:ok, notification} =
        for _ <- 1..3, reduce: nil do
          _ -> Notifications.notify(account, account_fixture(), "reblog", status_id: status.id)
        end

      assert json_response(
               post(conn, "/api/v2/notifications/#{notification.group_key}/dismiss"),
               200
             ) == %{}

      assert json_response(get(conn, "/api/v2/notifications"), 200)["notification_groups"] == []
    end

    test "counts groups rather than rows", %{conn: conn, account: account} do
      # Forty people favouriting one post is one thing that happened, and a
      # badge saying forty is a badge saying the reader missed forty things.
      status = status_fixture(%{account_id: account.id})

      for _ <- 1..3,
          do: Notifications.notify(account, account_fixture(), "reblog", status_id: status.id)

      assert %{"count" => 1} = json_response(get(conn, "/api/v2/notifications/unread_count"), 200)
      assert %{"count" => 3} = json_response(get(conn, "/api/v1/notifications/unread_count"), 200)
    end

    test "the policy and clear answer under v2 as well", %{conn: conn, account: account} do
      Notifications.notify(account, account_fixture(), "follow")

      assert %{"for_not_following" => _} =
               json_response(get(conn, "/api/v2/notifications/policy"), 200)

      assert json_response(
               put(conn, "/api/v2/notifications/policy", %{"for_not_following" => "filter"}),
               200
             )["for_not_following"] == "filter"

      assert json_response(post(conn, "/api/v2/notifications/clear"), 200) == %{}
      assert json_response(get(conn, "/api/v2/notifications"), 200)["notification_groups"] == []
    end

    test "somebody else's group is not readable and not dismissable", %{conn: conn} do
      stranger = account_fixture()
      status = status_fixture(%{account_id: stranger.id})

      {:ok, theirs} =
        Notifications.notify(stranger, account_fixture(), "reblog", status_id: status.id)

      assert json_response(get(conn, "/api/v2/notifications/#{theirs.group_key}"), 404)

      assert json_response(post(conn, "/api/v2/notifications/#{theirs.group_key}/dismiss"), 200)
      assert length(Notifications.list(stranger)) == 1
    end

    test "the count comes down as somebody reads", %{conn: conn, account: account} do
      # Unread means past where the reader said they had got to. A count that
      # ignored the marker would show a number nothing brings down.
      {:ok, notification} = Notifications.notify(account, account_fixture(), "follow")

      assert %{"count" => 1} = json_response(get(conn, "/api/v2/notifications/unread_count"), 200)

      {:ok, _} =
        Abuuba.Timelines.put_marker(account, "notifications", to_string(notification.id))

      assert %{"count" => 0} = json_response(get(conn, "/api/v2/notifications/unread_count"), 200)
      assert %{"count" => 0} = json_response(get(conn, "/api/v1/notifications/unread_count"), 200)
    end

    test "everybody in one group", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id})

      {:ok, notification} =
        Notifications.notify(account, account_fixture(), "reblog", status_id: status.id)

      body =
        json_response(get(conn, "/api/v2/notifications/#{notification.group_key}/accounts"), 200)

      assert length(body) == 1
    end
  end

  describe "the policy" do
    test "reads back what was set", %{conn: conn} do
      assert json_response(
               put(conn, "/api/v1/notifications/policy", %{"for_bots" => "drop"}),
               200
             )[
               "for_bots"
             ] == "drop"

      assert json_response(get(conn, "/api/v1/notifications/policy"), 200)["for_bots"] == "drop"
    end

    test "defaults are readable before anybody sets one", %{conn: conn} do
      body = json_response(get(conn, "/api/v1/notifications/policy"), 200)

      assert body["for_not_following"] == "accept"
      assert body["for_private_mentions"] == "filter"
    end

    test "refuses a decision nobody defined", %{conn: conn} do
      conn = put(conn, "/api/v1/notifications/policy", %{"for_bots" => "maybe"})

      assert json_response(conn, 422)["details"]["for_bots"]
    end
  end

  describe "the requests inbox" do
    setup %{conn: conn, account: account} do
      {:ok, _} = Notifications.put_policy(account, %{"for_not_following" => "filter"})
      sender = account_fixture()
      {:ok, _} = Notifications.notify(account, sender, "mention")

      %{conn: conn, sender: sender}
    end

    test "lists a sender once with a count", %{conn: conn, sender: sender} do
      assert [request] = json_response(get(conn, "/api/v1/notifications/requests"), 200)

      assert request["account"]["id"] == to_string(sender.id)
      assert request["notifications_count"] == "1"
    end

    test "reads one back by the id it handed out", %{conn: conn, sender: sender} do
      [%{"id" => id}] = json_response(get(conn, "/api/v1/notifications/requests"), 200)

      request = json_response(get(conn, "/api/v1/notifications/requests/#{id}"), 200)

      assert request["id"] == id
      assert request["account"]["id"] == to_string(sender.id)
    end

    test "an id nobody has is a plain miss", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/notifications/requests/999999"), 404)
    end

    test "one already put away is gone from both the list and the id", %{conn: conn} do
      [%{"id" => id}] = json_response(get(conn, "/api/v1/notifications/requests"), 200)

      assert json_response(post(conn, "/api/v1/notifications/requests/#{id}/dismiss"), 200)

      assert json_response(get(conn, "/api/v1/notifications/requests"), 200) == []
      assert json_response(get(conn, "/api/v1/notifications/requests/#{id}"), 404)
    end

    test "accepting moves what was filed", %{conn: conn, account: account} do
      # By the id the list handed out, which is the request's own. It is not
      # the sender's account id, and acting on that number would act on
      # whoever happened to have it.
      [%{"id" => id}] = json_response(get(conn, "/api/v1/notifications/requests"), 200)

      assert json_response(post(conn, "/api/v1/notifications/requests/#{id}/accept"), 200)

      assert length(Notifications.list(account)) == 1
      assert json_response(get(conn, "/api/v1/notifications/requests"), 200) == []
    end

    test "dismissing hides it and keeps them filtered", %{
      conn: conn,
      account: account
    } do
      [%{"id" => id}] = json_response(get(conn, "/api/v1/notifications/requests"), 200)

      assert json_response(post(conn, "/api/v1/notifications/requests/#{id}/dismiss"), 200)

      assert Notifications.list(account) == []
      assert json_response(get(conn, "/api/v1/notifications/requests"), 200) == []
    end

    test "accepting several at once", %{conn: conn, account: account} do
      other = account_fixture()
      {:ok, _} = Notifications.notify(account, other, "mention")

      # The ids the list handed out, which are the requests' own.
      ids = Enum.map(Notifications.requests(account), &to_string(&1.id))

      assert json_response(
               post(conn, "/api/v1/notifications/requests/accept", %{"id" => ids}),
               200
             )

      assert json_response(get(conn, "/api/v1/notifications/requests"), 200) == []
    end

    test "says the inbox is ready, rather than 404ing a poll", %{conn: conn} do
      # A client polls this. A 404 would stop it polling.
      assert json_response(get(conn, "/api/v1/notifications/requests/merged"), 200)["merged"]
    end
  end

  describe "narrowing to one person, and to the waiting list" do
    test "account_id lists only what they did", %{conn: conn, account: account} do
      # A client asking "what has this person done to me" was given every
      # notification on the list instead, because the parameter was not read
      # and nothing behind it could have filtered on a sender anyway.
      one = account_fixture()
      other = account_fixture()

      {:ok, _} = Notifications.notify(account, one, "follow")
      {:ok, _} = Notifications.notify(account, other, "follow")

      body =
        conn
        |> get("/api/v1/notifications", %{"account_id" => to_string(one.id)})
        |> json_response(200)

      assert Enum.map(body, & &1["account"]["id"]) == [to_string(one.id)]
    end

    test "and shows their filtered ones too, which is the point of asking", %{
      conn: conn,
      account: account
    } do
      # The reference drops the filtered restriction when a sender is named:
      # somebody looking up one account has already decided to look at them,
      # and hiding half the answer behind the requests inbox would be a
      # strange thing to do to a direct question.
      stranger = account_fixture()
      {:ok, _} = Notifications.put_policy(account, %{"for_not_following" => "filter"})
      {:ok, notification} = Notifications.notify(account, stranger, "follow")

      assert notification.filtered

      body =
        conn
        |> get("/api/v1/notifications", %{"account_id" => to_string(stranger.id)})
        |> json_response(200)

      assert length(body) == 1
    end

    test "include_filtered lists both", %{conn: conn, account: account} do
      stranger = account_fixture()
      friend = account_fixture()
      {:ok, _follow} = Abuuba.Relationships.follow(account, friend)
      {:ok, _} = Notifications.put_policy(account, %{"for_not_following" => "filter"})

      {:ok, filtered} = Notifications.notify(account, stranger, "follow")
      {:ok, plain} = Notifications.notify(account, friend, "follow")

      assert filtered.filtered
      refute plain.filtered

      body =
        conn
        |> get("/api/v1/notifications", %{"include_filtered" => "true"})
        |> json_response(200)

      assert length(body) == 2
    end

    test "and without it only the unfiltered ones", %{conn: conn, account: account} do
      # The control: if `include_filtered` were simply ignored in the other
      # direction, the test above would pass on a server that never filters.
      stranger = account_fixture()
      {:ok, _} = Notifications.put_policy(account, %{"for_not_following" => "filter"})
      {:ok, _} = Notifications.notify(account, stranger, "follow")

      body = conn |> get("/api/v1/notifications") |> json_response(200)

      assert body == []
    end
  end
end

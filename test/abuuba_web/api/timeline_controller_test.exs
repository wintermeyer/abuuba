defmodule AbuubaWeb.API.TimelineControllerTest do
  use AbuubaWeb.ConnCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Timelines.Feed
  alias Abuuba.Timelines.RegenerateWorker

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

  describe "a feed that is still being put together" do
    test "answers 206 rather than an empty 200", %{conn: conn, account: account} do
      # An empty 200 tells a client there is nothing to read. A partial answer
      # tells it to come back, which is what is actually true.
      other = account_fixture()
      {:ok, _} = Relationships.follow(account, other)
      status_fixture(%{account_id: other.id})
      Feed.clear("home", account.id)

      conn = get(conn, "/api/v1/timelines/home")

      assert conn.status == 206
      assert get_resp_header(conn, "x-feed-regenerating") == ["true"]
      assert json_response(conn, 206) == []
    end

    test "queues the rebuild that will fill it", %{conn: conn, account: account} do
      other = account_fixture()
      {:ok, _} = Relationships.follow(account, other)
      status_fixture(%{account_id: other.id})
      Feed.clear("home", account.id)

      get(conn, "/api/v1/timelines/home")

      assert [_job] = all_enqueued(worker: RegenerateWorker)
    end

    test "an ordinary empty timeline is still a plain 200", %{conn: conn} do
      # Somebody following nobody is not waiting for anything.
      conn = get(conn, "/api/v1/timelines/home")

      assert json_response(conn, 200) == []
    end
  end

  describe "the home timeline" do
    test "carries what you follow", %{conn: conn, account: account} do
      author = account_fixture()
      {:ok, _} = Relationships.follow(account, author)
      status = status_fixture(%{account_id: author.id, text: "theirs"})

      assert [%{"id" => id}] = json_response(get(conn, "/api/v1/timelines/home"), 200)
      assert id == to_string(status.id)
    end

    test "needs a token, since there is no home without whose home it is", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/timelines/home"), 422)["error"]
    end

    test "carries a Link header when there is a page", %{conn: conn, account: account} do
      status_fixture(%{account_id: account.id})

      conn = get(conn, "/api/v1/timelines/home")

      assert [link] = get_resp_header(conn, "link")
      assert link =~ "max_id="
    end

    test "carries no Link header on an empty page", %{conn: conn} do
      # A next link pointing at nothing tells a client to keep asking.
      conn = get(conn, "/api/v1/timelines/home")

      assert json_response(conn, 200) == []
      assert get_resp_header(conn, "link") == []
    end

    # Every other test here follows one account and reads back one post, and a
    # page of one is the same page whichever end the limit bites at. That is
    # how the feed came to be read oldest-first through the API for as long as
    # it was: the request always carries a `min_id` key, `nil` when the client
    # did not send one, and the ordering matched on the key being there rather
    # than on it having a value. A reader saw the bottom of their feed.
    test "serves the newest posts, not the oldest, when a page cannot hold them all",
         %{conn: conn, account: account} do
      author = account_fixture()
      {:ok, _} = Relationships.follow(account, author)

      posts = for n <- 1..5, do: status_fixture(%{account_id: author.id, text: "post #{n}"})

      body = json_response(get(conn, "/api/v1/timelines/home?limit=3"), 200)

      newest = posts |> Enum.take(-3) |> Enum.reverse() |> Enum.map(&to_string(&1.id))
      assert Enum.map(body, & &1["id"]) == newest
    end

    test "still pages upward from a min_id cursor, oldest end first",
         %{conn: conn, account: account} do
      # The other side of the same switch: when `min_id` really is given, the
      # limit has to bite at the oldest end so the page fills the gap the
      # client is walking towards rather than skipping over it.
      author = account_fixture()
      {:ok, _} = Relationships.follow(account, author)

      posts = for n <- 1..5, do: status_fixture(%{account_id: author.id, text: "post #{n}"})
      cursor = Enum.at(posts, 1)

      body = json_response(get(conn, "/api/v1/timelines/home?min_id=#{cursor.id}&limit=2"), 200)

      expected = posts |> Enum.slice(2, 2) |> Enum.reverse() |> Enum.map(&to_string(&1.id))
      assert Enum.map(body, & &1["id"]) == expected
    end
  end

  describe "the public timeline" do
    setup %{account: account} do
      %{status: status_fixture(%{account_id: account.id, text: "hello"})}
    end

    test "is readable without a token by default", %{anon: anon, status: status} do
      assert [%{"id" => id}] = json_response(get(anon, "/api/v1/timelines/public"), 200)
      assert id == to_string(status.id)
    end

    test "can be closed to strangers", %{anon: anon, conn: conn} do
      # A server that is a private community does not want its timeline read
      # by anybody who finds the URL.
      Settings.put("timeline_access", "authenticated")

      assert json_response(get(anon, "/api/v1/timelines/public"), 422)["error"]
      assert json_response(get(conn, "/api/v1/timelines/public"), 200) != []

      Settings.put("timeline_access", "public")
    end

    test "can be turned off entirely, and then there is nothing there", %{conn: conn} do
      # 404 rather than 403: the server is saying there is nothing here, not
      # that you are unwelcome.
      Settings.put("timeline_access", "disabled")

      assert json_response(get(conn, "/api/v1/timelines/public"), 404)["error"]

      Settings.put("timeline_access", "public")
    end

    test "takes the local flag", %{anon: anon, status: status} do
      conn = get(anon, "/api/v1/timelines/public", %{"local" => "true"})

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(status.id)
    end
  end

  describe "a hashtag timeline" do
    test "carries posts under the tag", %{anon: anon, account: account} do
      status = status_fixture(%{account_id: account.id})
      :ok = Statuses.tag_status(status, tag_fixture("cats"))

      assert [%{"id" => id}] = json_response(get(anon, "/api/v1/timelines/tag/cats"), 200)
      assert id == to_string(status.id)
    end

    test "takes the any, all and none combinations", %{anon: anon, account: account} do
      cats = tag_fixture("cats")
      dogs = tag_fixture("dogs")

      both = status_fixture(%{account_id: account.id})
      :ok = Statuses.tag_status(both, cats)
      :ok = Statuses.tag_status(both, dogs)

      only_cats = status_fixture(%{account_id: account.id})
      :ok = Statuses.tag_status(only_cats, cats)

      assert [%{"id" => id}] =
               json_response(get(anon, "/api/v1/timelines/tag/cats", %{"all" => ["dogs"]}), 200)

      assert id == to_string(both.id)

      assert [%{"id" => other}] =
               json_response(get(anon, "/api/v1/timelines/tag/cats", %{"none" => ["dogs"]}), 200)

      assert other == to_string(only_cats.id)
    end
  end

  describe "the timelines that need something else first" do
    test "a list says there is no such list", %{conn: conn} do
      # An empty list and a list that does not exist are different things, and
      # a client shows them differently.
      assert json_response(get(conn, "/api/v1/timelines/list/1"), 404)["error"]
    end

    test "links answer with nothing rather than an error", %{anon: anon} do
      assert json_response(
               get(anon, "/api/v1/timelines/link", %{"url" => "https://x.example"}),
               200
             ) ==
               []
    end
  end

  describe "markers" do
    test "remember where somebody was", %{conn: conn} do
      post(conn, "/api/v1/markers", %{"home" => %{"last_read_id" => "123"}})

      body = json_response(get(conn, "/api/v1/markers", %{"timeline" => ["home"]}), 200)

      assert body["home"]["last_read_id"] == "123"
      assert body["home"]["version"] == 1
    end

    test "answer with the version a client has to send back", %{conn: conn} do
      body =
        json_response(post(conn, "/api/v1/markers", %{"home" => %{"last_read_id" => "1"}}), 200)

      assert body["home"]["version"] == 1
      assert body["home"]["updated_at"]
    end

    test "refuse a write against a stale version with 409", %{conn: conn} do
      # Two clients both holding a marker is the ordinary case. Silently
      # overwriting would drag somebody's place backwards.
      post(conn, "/api/v1/markers", %{"home" => %{"last_read_id" => "1"}})
      post(conn, "/api/v1/markers", %{"home" => %{"last_read_id" => "2"}})

      conn =
        post(conn, "/api/v1/markers", %{
          "home" => %{"last_read_id" => "3", "version" => "1"}
        })

      assert json_response(conn, 409)["error"] =~ "Conflict"
    end

    test "accept a write naming the version it holds", %{conn: conn} do
      first =
        json_response(post(conn, "/api/v1/markers", %{"home" => %{"last_read_id" => "1"}}), 200)

      conn =
        post(conn, "/api/v1/markers", %{
          "home" => %{"last_read_id" => "2", "version" => to_string(first["home"]["version"])}
        })

      assert json_response(conn, 200)["home"]["last_read_id"] == "2"
    end

    test "need a token", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/markers"), 422)["error"]
    end
  end
end

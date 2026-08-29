defmodule AbuubaWeb.AsyncRefreshesTest do
  use AbuubaWeb.ConnCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  import Abuuba.AccountsFixtures

  alias Abuuba.AsyncRefreshes
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.StatusesFixtures
  alias Abuuba.Timelines
  alias Abuuba.Timelines.RegenerateWorker
  alias AbuubaWeb.API.AsyncRefreshHeader

  setup %{conn: conn} do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{conn: put_req_header(conn, "authorization", "Bearer " <> raw), account: account}
  end

  describe "starting one" do
    test "twice for the same work joins the first", %{account: account} do
      assert {:started, first} = AsyncRefreshes.start(account, "home_feed")
      assert {:joined, second} = AsyncRefreshes.start(account, "home_feed")

      assert first.id == second.id
    end

    test "again after the first finished starts a new one", %{account: account} do
      {:started, first} = AsyncRefreshes.start(account, "home_feed")
      :ok = AsyncRefreshes.finish(first)

      assert {:started, second} = AsyncRefreshes.start(account, "home_feed")
      refute second.id == first.id
    end

    test "counts results only when asked to", %{account: account} do
      {:started, counting} = AsyncRefreshes.start(account, "counted", count_results: true)
      {:started, plain} = AsyncRefreshes.start(account, "plain")

      assert counting.result_count == 0
      assert is_nil(plain.result_count)
    end
  end

  describe "finishing one" do
    test "records the count and stops it running", %{account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "home_feed", count_results: true)

      :ok = AsyncRefreshes.finish(refresh, result_count: 12)

      reloaded = AsyncRefreshes.get(account, refresh.id)
      assert reloaded.status == "finished"
      assert reloaded.result_count == 12
    end

    test "twice is finishing once", %{account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "home_feed")

      assert :ok = AsyncRefreshes.finish(refresh)
      assert :ok = AsyncRefreshes.finish(refresh)
    end

    test "by id survives the row having been swept", %{account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "home_feed")
      Abuuba.Repo.delete!(refresh)

      assert :ok = AsyncRefreshes.finish(refresh.id)
    end
  end

  describe "GET /api/v1_alpha/async_refreshes/:id" do
    test "reports the state to the account that started it", %{conn: conn, account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "home_feed", count_results: true)

      body =
        conn
        |> get(~p"/api/v1_alpha/async_refreshes/#{refresh.id}")
        |> json_response(200)

      assert body["async_refresh"]["id"] == to_string(refresh.id)
      assert body["async_refresh"]["status"] == "running"
      assert body["async_refresh"]["result_count"] == 0
    end

    test "reports a finished one as finished", %{conn: conn, account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "home_feed", count_results: true)
      :ok = AsyncRefreshes.finish(refresh, result_count: 7)

      body =
        conn
        |> get(~p"/api/v1_alpha/async_refreshes/#{refresh.id}")
        |> json_response(200)

      assert body["async_refresh"]["status"] == "finished"
      assert body["async_refresh"]["result_count"] == 7
    end

    test "reports null rather than zero for one that does not count", %{
      conn: conn,
      account: account
    } do
      # What the reference implementation emits, and therefore what clients
      # parse. Zero would say "nothing found yet" about work with nothing to
      # find.
      {:started, refresh} = AsyncRefreshes.start(account, "plain")

      body =
        conn
        |> get(~p"/api/v1_alpha/async_refreshes/#{refresh.id}")
        |> json_response(200)

      assert is_nil(body["async_refresh"]["result_count"])
    end

    test "refuses somebody else's", %{conn: conn} do
      stranger = account_fixture()
      {:started, refresh} = AsyncRefreshes.start(stranger, "home_feed")

      conn
      |> get(~p"/api/v1_alpha/async_refreshes/#{refresh.id}")
      |> json_response(404)
    end

    test "refuses an id that is not one", %{conn: conn} do
      conn |> get(~p"/api/v1_alpha/async_refreshes/not-an-id") |> json_response(404)
    end

    test "refuses an id too large for the column", %{conn: conn} do
      # `Integer.parse/1` would happily return this and Postgrex would then
      # raise on encoding it, turning a bad URL into a 500 anybody can trigger.
      conn |> get(~p"/api/v1_alpha/async_refreshes/99999999999999999999") |> json_response(404)
    end

    test "refuses anonymously", %{account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "home_feed")

      build_conn()
      |> get(~p"/api/v1_alpha/async_refreshes/#{refresh.id}")
      |> json_response(422)
    end
  end

  describe "the home timeline while it is being rebuilt" do
    setup %{account: account} do
      # A follow, so the feed is one that ought to have something in it. An
      # account following nobody has an empty feed on purpose.
      Relationships.follow(account, account_fixture())

      :ok
    end

    test "names a refresh a client can watch", %{conn: conn, account: account} do
      conn = get(conn, ~p"/api/v1/timelines/home")

      assert conn.status == 206
      assert [value] = get_resp_header(conn, "mastodon-async-refresh")
      assert value =~ ~r/^id="\d+", retry=5, result_count=0$/

      assert %{} = AsyncRefreshes.running(account, "home_feed")
    end

    test "names the same refresh on a second ask", %{conn: conn} do
      first = conn |> get(~p"/api/v1/timelines/home") |> get_resp_header("mastodon-async-refresh")

      second =
        conn |> get(~p"/api/v1/timelines/home") |> get_resp_header("mastodon-async-refresh")

      assert first == second
    end

    test "queues the rebuild again for a request that joined", %{conn: conn, account: account} do
      # The regression this guards: queueing only for the request that created
      # the refresh means a job that exhausted its attempts leaves a running
      # row nothing will ever finish, and every later request joins it and
      # queues nothing — an empty home feed that stays empty for a whole day.
      {:started, _first} = AsyncRefreshes.start(account, "home_feed", count_results: true)

      conn |> get(~p"/api/v1/timelines/home") |> response(206)

      assert [_job] = Abuuba.Repo.all(Oban.Job)
    end

    test "takes over a running row whose day has passed", %{conn: conn, account: account} do
      {:started, stale} = AsyncRefreshes.start(account, "home_feed", count_results: true)

      # Its worker died and the sweep has not been round yet. The partial
      # unique index still holds the row, so without a takeover the next
      # request is told nothing is trackable and the client has nothing to poll.
      stale
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Abuuba.Repo.update!()

      assert [value] =
               conn
               |> get(~p"/api/v1/timelines/home")
               |> get_resp_header("mastodon-async-refresh")

      refute value =~ "id=\"#{stale.id}\""
    end

    test "queues a job for a fresh refresh after an earlier one completed", %{
      conn: conn,
      account: account
    } do
      # What the smoke test caught: deduping the job per account rather than
      # per refresh swallows the enqueue for the refresh made after an earlier
      # job completed, and that refresh then sits `running` for its whole day
      # with nothing on its way to finish it.
      conn |> get(~p"/api/v1/timelines/home") |> response(206)
      Oban.drain_queue(queue: :ingress)

      account |> AsyncRefreshes.running("home_feed") |> AsyncRefreshes.finish(result_count: 0)

      conn |> get(~p"/api/v1/timelines/home") |> response(206)

      fresh = AsyncRefreshes.running(account, "home_feed")
      Oban.drain_queue(queue: :ingress)

      assert AsyncRefreshes.get(account, fresh.id).status == "finished"
    end

    test "names a fresh one once the last rebuild finished", %{conn: conn, account: account} do
      [first] =
        conn |> get(~p"/api/v1/timelines/home") |> get_resp_header("mastodon-async-refresh")

      account |> AsyncRefreshes.running("home_feed") |> AsyncRefreshes.finish(result_count: 0)

      # The feed is still empty and still ought not to be, so asking again is
      # asking for another rebuild. What must not happen is being pointed back
      # at the finished one, which can never change again.
      [second] =
        conn |> get(~p"/api/v1/timelines/home") |> get_resp_header("mastodon-async-refresh")

      refute second == first
    end
  end

  describe "the header" do
    test "is not sent for a refresh that has finished", %{conn: conn, account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "home_feed", count_results: true)
      :ok = AsyncRefreshes.finish(refresh)

      finished = AsyncRefreshes.get(account, refresh.id)

      assert conn
             |> AsyncRefreshHeader.put(finished)
             |> get_resp_header("mastodon-async-refresh") == []
    end

    test "omits the count for work that has nothing to count", %{conn: conn, account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "plain")

      assert [value] =
               conn
               |> AsyncRefreshHeader.put(refresh)
               |> get_resp_header("mastodon-async-refresh")

      refute value =~ "result_count"
    end

    test "does nothing when no refresh could be started", %{conn: conn} do
      assert AsyncRefreshHeader.put(conn, :error)
             |> get_resp_header("mastodon-async-refresh") == []
    end
  end

  describe "the rebuild worker" do
    test "finishes the refresh with how much it found", %{account: account} do
      other = account_fixture()
      Relationships.follow(account, other)
      StatusesFixtures.status_fixture(%{account_id: other.id})

      {:started, refresh} = AsyncRefreshes.start(account, "home_feed", count_results: true)

      assert :ok =
               perform_job(RegenerateWorker, %{
                 "account_id" => account.id,
                 "async_refresh_id" => refresh.id
               })

      reloaded = AsyncRefreshes.get(account, refresh.id)
      assert reloaded.status == "finished"
      assert reloaded.result_count == Timelines.home_size(account)
      assert reloaded.result_count > 0
    end

    test "runs fine for a rebuild nobody is watching", %{account: account} do
      assert :ok =
               perform_job(RegenerateWorker, %{
                 "account_id" => account.id,
                 "async_refresh_id" => nil
               })
    end
  end

  describe "sweeping" do
    test "deletes the rows nobody can read any more", %{account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "home_feed")

      refresh
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Abuuba.Repo.update!()

      assert AsyncRefreshes.sweep() >= 1
      assert is_nil(AsyncRefreshes.get(account, refresh.id))
    end

    test "leaves a live one alone", %{account: account} do
      {:started, refresh} = AsyncRefreshes.start(account, "home_feed")

      AsyncRefreshes.sweep()

      assert %{} = AsyncRefreshes.get(account, refresh.id)
    end
  end
end

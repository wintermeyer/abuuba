defmodule AbuubaWeb.AnnualReportsTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.AnnualReports
  alias Abuuba.Notifications
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  @year 2026

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    on_exit(fn -> Application.put_env(:abuuba, :annual_report_campaign, :never) end)

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      anon: build_conn(),
      account: account
    }
  end

  # A second conn carrying the same credentials, for asserting that two
  # requests get the same answer.
  defp build_conn_like(conn) do
    [auth] = Plug.Conn.get_req_header(conn, "authorization")

    put_req_header(build_conn(), "authorization", auth)
  end

  defp open_campaign(year \\ @year),
    do: Application.put_env(:abuuba, :annual_report_campaign, year)

  defp posted(account, n) do
    for _ <- 1..n, do: status_fixture(%{account_id: account.id, text: "something #gardening"})
  end

  describe "a year that cannot be a row" do
    # `annual_reports.year` is a Postgres `integer`, so anything outside int4
    # cannot name a report. It used to reach the query anyway and Postgrex
    # refused to encode it, which came back as a 500 — on a public page, to
    # anybody who asked.
    @too_big "99999999999"

    test "is a 404 on the page anyone can reach", %{anon: anon, account: account} do
      assert_error_sent 404, fn ->
        get(anon, ~p"/@#{account.username}/year/#{@too_big}")
      end
    end

    test "answers a client exactly as an ordinary absent year does", %{conn: conn} do
      # Stronger than asserting a status: the impossible year is not a special
      # case at all, it is simply a year with no report, which is what 1999 is
      # too. A test naming one status would go stale the moment that answer
      # changed for good reasons.
      impossible = get(conn, ~p"/api/v1/annual_reports/#{@too_big}/state")
      ordinary = get(build_conn_like(conn), ~p"/api/v1/annual_reports/1999/state")

      assert json_response(impossible, 200) == json_response(ordinary, 200)
    end

    test "and refuses to generate one the same way", %{conn: conn} do
      impossible = post(conn, ~p"/api/v1/annual_reports/#{@too_big}/generate")
      ordinary = post(build_conn_like(conn), ~p"/api/v1/annual_reports/1999/generate")

      assert json_response(impossible, 422) == json_response(ordinary, 422)
    end

    test "but the largest year that fits still answers normally", %{conn: conn} do
      # The boundary, and the positive control: if the guard were simply
      # refusing everything, the three tests above would pass just as well.
      conn = get(conn, ~p"/api/v1/annual_reports/2147483647/state")

      assert %{"state" => "ineligible"} = json_response(conn, 200)
    end
  end

  describe "the campaign window" do
    test "is a fortnight in December, not whenever the tests run" do
      # Both sides of the gate, on a fixed clock. Reading the real one would
      # make this pass all year and fail on the 1st of January.
      Application.put_env(:abuuba, :annual_report_campaign, :calendar)

      assert AnnualReports.current_campaign(~D[2026-12-10]) == 2026
      assert AnnualReports.current_campaign(~D[2026-12-31]) == 2026
      refute AnnualReports.current_campaign(~D[2026-12-09])
      refute AnnualReports.current_campaign(~D[2026-11-30])
      refute AnnualReports.current_campaign(~D[2027-01-01])
    end
  end

  describe "asking where a year stands" do
    test "is ineligible outside the window, however much somebody posted", %{
      conn: conn,
      account: account
    } do
      posted(account, 3)

      assert %{"state" => "ineligible"} =
               json_response(get(conn, "/api/v1/annual_reports/#{@year}/state"), 200)
    end

    test "is eligible inside it once there is a year to report on", %{
      conn: conn,
      account: account
    } do
      open_campaign()
      posted(account, 3)

      assert %{"state" => "eligible"} =
               json_response(get(conn, "/api/v1/annual_reports/#{@year}/state"), 200)
    end

    test "one post is not a year in review", %{conn: conn, account: account} do
      # A report saying somebody posted once reads as the server being
      # sarcastic.
      open_campaign()
      posted(account, 1)

      assert %{"state" => "ineligible"} =
               json_response(get(conn, "/api/v1/annual_reports/#{@year}/state"), 200)
    end

    test "becomes available once one exists", %{conn: conn, account: account} do
      open_campaign()
      posted(account, 3)
      {:ok, _report} = AnnualReports.generate(account, @year)

      assert %{"state" => "available"} =
               json_response(get(conn, "/api/v1/annual_reports/#{@year}/state"), 200)
    end
  end

  describe "generating one" do
    setup %{account: account} do
      open_campaign()
      posted(account, 3)

      :ok
    end

    test "builds it, tells its owner, and answers the same the second time", %{
      conn: conn,
      account: account
    } do
      body = json_response(post(conn, "/api/v1/annual_reports/#{@year}/generate"), 200)

      assert [report] = body["annual_reports"]
      assert report["year"] == @year
      assert report["data"]["archetype"]
      assert is_list(report["data"]["time_series"])

      # Told, or nobody looks: the whole feature is a notification in December.
      assert Enum.any?(Notifications.list(account), &(&1.type == "annual_report"))

      # Asking twice is asking once, rather than an error the second time.
      again = json_response(post(conn, "/api/v1/annual_reports/#{@year}/generate"), 200)
      assert again == body
    end

    test "counts the months, the hashtags and what travelled furthest", %{
      conn: conn,
      account: account
    } do
      loud = status_fixture(%{account_id: account.id, text: "the one that went far"})
      {:ok, _} = Statuses.favourite(account_fixture(), loud)

      follower = account_fixture()
      {:ok, _} = Relationships.follow(follower, account)

      [report] =
        json_response(post(conn, "/api/v1/annual_reports/#{@year}/generate"), 200)[
          "annual_reports"
        ]

      data = report["data"]

      assert length(data["time_series"]) == 12
      assert Enum.sum(Enum.map(data["time_series"], & &1["statuses"])) >= 3
      assert Enum.sum(Enum.map(data["time_series"], & &1["followers"])) == 1
      assert [%{"name" => "gardening"} | _] = data["top_hashtags"]
      assert [%{"id" => _} | _] = data["top_statuses"]
    end

    test "carries the posts it names alongside rather than inside", %{conn: conn} do
      body = json_response(post(conn, "/api/v1/annual_reports/#{@year}/generate"), 200)

      assert [_ | _] = body["statuses"]
    end

    test "refuses outside the window", %{conn: conn} do
      Application.put_env(:abuuba, :annual_report_campaign, :never)

      assert json_response(post(conn, "/api/v1/annual_reports/#{@year}/generate"), 422)
    end
  end

  describe "the list and the card" do
    setup %{account: account} do
      open_campaign()
      posted(account, 3)
      {:ok, report} = AnnualReports.generate(account, @year)

      %{report: report}
    end

    test "lists what has not been looked at, and stops once it has", %{
      conn: conn,
      report: report
    } do
      assert [%{"year" => @year}] =
               json_response(get(conn, "/api/v1/annual_reports"), 200)["annual_reports"]

      assert json_response(post(conn, "/api/v1/annual_reports/#{report.id}/read"), 200) == %{}

      assert json_response(get(conn, "/api/v1/annual_reports"), 200)["annual_reports"] == []
      # Still readable by id: read means "stop offering it", not "throw it away".
      assert json_response(get(conn, "/api/v1/annual_reports/#{report.id}"), 200)
    end

    test "somebody else's is not readable", %{report: report} do
      stranger = account_fixture()

      user =
        user_fixture(%{account_id: stranger.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, application, _secret} =
        OAuth.create_application(%{name: "t2", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

      conn = put_req_header(build_conn(), "authorization", "Bearer " <> raw)

      assert json_response(get(conn, "/api/v1/annual_reports/#{report.id}"), 404)
      assert json_response(post(conn, "/api/v1/annual_reports/#{report.id}/read"), 404)
    end

    test "needs a token", %{anon: anon} do
      assert json_response(get(anon, "/api/v1/annual_reports"), 422)
    end
  end

  describe "the share page" do
    test "renders for a stranger, with the preview tags a chat window reads", %{
      conn: conn,
      anon: anon,
      account: account
    } do
      open_campaign()
      posted(account, 3)
      json_response(post(conn, "/api/v1/annual_reports/#{@year}/generate"), 200)

      html = anon |> get("/@alice/year/#{@year}") |> html_response(200)

      assert html =~ to_string(@year)
      assert html =~ "gardening"
      assert html =~ ~s(property="og:title")
      # The claim the page can honestly support.
      assert html =~ "public posts only"
    end

    test "a year nobody has a report for is a plain miss", %{anon: anon} do
      assert_error_sent 404, fn -> get(anon, "/@alice/year/1999") end
    end
  end

  describe "what a report counts" do
    test "leaves out posts a visitor could not have seen anyway", %{account: account} do
      # The page is public, so a report that counted followers-only posts would
      # publish how much somebody writes where nobody can check.
      open_campaign()
      posted(account, 2)

      for _ <- 1..5 do
        status_fixture(%{account_id: account.id, visibility: "private", text: "quiet #secret"})
      end

      {:ok, report} = AnnualReports.generate(account, @year)

      counted = Enum.sum(Enum.map(report.data["time_series"], & &1["statuses"]))

      assert counted == 2
      refute Enum.any?(report.data["top_hashtags"], &(&1["name"] == "secret"))
    end
  end
end

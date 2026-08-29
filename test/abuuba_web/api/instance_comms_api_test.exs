defmodule AbuubaWeb.API.InstanceCommsAPITest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.LoginActivities
  alias Abuuba.Instance
  alias Abuuba.Invites
  alias Abuuba.OAuth
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings

  describe "the terms endpoint" do
    test "serves the version in force", %{conn: conn} do
      {:ok, _} =
        Instance.publish_terms(account_fixture(), %{
          text: "Do not do anything illegal.",
          effective_date: Date.utc_today()
        })

      body = json_response(get(conn, "/api/v1/instance/terms_of_service"), 200)

      assert body["content"] == "Do not do anything illegal."
      assert body["effective_date"] == Date.to_iso8601(Date.utc_today())
    end

    test "and an older one by date", %{conn: conn} do
      old = Date.add(Date.utc_today(), -30)
      {:ok, _} = Instance.publish_terms(account_fixture(), %{text: "Old", effective_date: old})

      {:ok, _} =
        Instance.publish_terms(account_fixture(), %{text: "New", effective_date: Date.utc_today()})

      body = json_response(get(conn, "/api/v1/instance/terms_of_service/#{old}"), 200)

      assert body["content"] == "Old"
    end

    test "404 on a server that has written none", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/instance/terms_of_service"), 404)["error"]
    end
  end

  describe "rules" do
    test "come back in the reader's language", %{conn: conn} do
      {:ok, _} =
        Settings.create_rule(%{text: "Be kind.", translations: %{"de" => "Sei nett."}})

      conn = conn |> put_req_header("accept-language", "de") |> get("/api/v1/instance/rules")

      assert [%{"text" => "Sei nett."}] = json_response(conn, 200)
    end

    test "and in the original where nobody translated them", %{conn: conn} do
      {:ok, _} = Settings.create_rule(%{text: "Be kind."})

      conn = conn |> put_req_header("accept-language", "de") |> get("/api/v1/instance/rules")

      assert [%{"text" => "Be kind."}] = json_response(conn, 200)
    end
  end

  describe "the activity graph" do
    setup do
      on_exit(fn -> Settings.put("limited_federation", false) end)
    end

    test "answers twelve weeks of real numbers, as strings", %{conn: conn} do
      # It answered `[]` unconditionally -- the same shape as the preferences
      # bug, a constant where an answer belongs. Server-comparison sites read
      # this to chart a server's health, and a flat nothing reads as a dead
      # server.
      author = account_fixture()
      status_fixture(%{account_id: author.id, text: "counted"})

      user = user_fixture(%{account_id: account_fixture().id})
      :ok = LoginActivities.record(user.id, success: true)

      body = json_response(get(conn, "/api/v1/instance/activity"), 200)

      assert length(body) == 12

      [this_week | rest] = body

      # Strings, all of them, which is what the reference implementation sends
      # and therefore what the crawlers parse.
      assert %{
               "week" => week,
               "statuses" => statuses,
               "logins" => logins,
               "registrations" => registrations
             } = this_week

      monday = Date.beginning_of_week(Date.utc_today())

      assert week ==
               monday |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix() |> Integer.to_string()

      assert String.to_integer(statuses) >= 1
      assert String.to_integer(logins) >= 1
      assert String.to_integer(registrations) >= 1

      # A young server's history is zeros, not gaps.
      assert length(rest) == 11
      assert Enum.all?(rest, &(&1["statuses"] == "0"))
    end

    test "keeps the login count after the privacy sweep takes the detail", %{conn: conn} do
      # `login_activities` is deliberately swept after 30 days; the graph
      # answers twelve weeks. The weekly number is frozen before the sweep so
      # the count outlives the record of who signed in from where.
      user = user_fixture(%{account_id: account_fixture().id})
      :ok = LoginActivities.record(user.id, success: true)

      first = json_response(get(conn, "/api/v1/instance/activity"), 200)
      assert hd(first)["logins"] == "1"

      Repo.delete_all(Abuuba.Accounts.LoginActivity)

      after_sweep = json_response(get(conn, "/api/v1/instance/activity"), 200)
      assert hd(after_sweep)["logins"] == "1"
    end

    test "a failed sign-in is not activity", %{conn: conn} do
      user = user_fixture(%{account_id: account_fixture().id})
      :ok = LoginActivities.record(user.id, success: false, reason: "bad_password")

      body = json_response(get(conn, "/api/v1/instance/activity"), 200)

      assert hd(body)["logins"] == "0"
    end

    test "says nothing at all in limited federation mode", %{conn: conn} do
      # The reference implementation answers 404 there: a server that talks
      # only to its allowlist is not publishing its vital signs to strangers.
      :ok = Settings.put("limited_federation", true)

      assert conn |> get("/api/v1/instance/activity") |> response(404)
    end
  end

  describe "invites" do
    setup %{conn: conn} do
      {:ok, role} =
        Roles.create(%{
          name: "Inviter #{System.unique_integer([:positive])}",
          position: 10,
          permissions: Roles.mask(["invite_users"])
        })

      account = account_fixture()

      user =
        user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, _} = Roles.assign(user, role)

      {:ok, application, _secret} =
        OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

      %{conn: put_req_header(conn, "authorization", "Bearer " <> raw), account: account}
    end

    test "can be made and listed", %{conn: conn} do
      body = json_response(post(conn, "/api/v1/invites", %{"max_uses" => 3}), 200)

      assert body["code"]
      assert body["max_uses"] == 3
      assert body["url"] =~ body["code"]

      assert [listed] = json_response(get(conn, "/api/v1/invites"), 200)
      assert listed["id"] == body["id"]
    end

    test "are only your own", %{conn: conn} do
      # An invite names who vouched. A list of everybody's would say who is
      # vouching for whom, which is not what the permission grants.
      stranger = account_fixture()
      {:ok, _} = Invites.create(with_invite_permission(stranger), %{})

      assert json_response(get(conn, "/api/v1/invites"), 200) == []
    end

    test "can be taken back", %{conn: conn} do
      body = json_response(post(conn, "/api/v1/invites", %{}), 200)

      assert json_response(delete(conn, "/api/v1/invites/#{body["id"]}"), 200)
      assert json_response(get(conn, "/api/v1/invites"), 200) == []
    end

    test "need the permission", %{} do
      account = account_fixture()
      user = user_fixture(%{account_id: account.id, approved: true})

      {:ok, application, _secret} =
        OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

      conn = build_conn() |> put_req_header("authorization", "Bearer " <> raw)

      assert json_response(post(conn, "/api/v1/invites", %{}), 403)["error"]
    end
  end

  defp with_invite_permission(account) do
    {:ok, role} =
      Roles.create(%{
        name: "Inviter #{System.unique_integer([:positive])}",
        position: 10,
        permissions: Roles.mask(["invite_users"])
      })

    user = user_fixture(%{account_id: account.id, approved: true})
    {:ok, _} = Roles.assign(user, role)

    account
  end
end

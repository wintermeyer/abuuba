defmodule AbuubaWeb.API.AdminGapsTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Account
  alias Abuuba.Moderation.Reports
  alias Abuuba.OAuth
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Statuses
  alias Abuuba.Trends

  defp signed_in_with(conn, permissions) do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 10,
        permissions: Roles.mask(permissions)
      })

    {:ok, user} = Roles.assign(user, role)

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} =
      OAuth.issue_token(application, user, ["read", "write", "admin:read", "admin:write"])

    %{conn: put_req_header(conn, "authorization", "Bearer " <> raw), account: account}
  end

  setup %{conn: conn} do
    %{conn: conn, account: moderator} =
      signed_in_with(conn, [
        "manage_users",
        "manage_reports",
        "manage_taxonomies",
        "manage_federation"
      ])

    %{conn: conn, plain: signed_in_with(build_conn(), []).conn, moderator: moderator}
  end

  describe "hashtags" do
    test "lists, reads and decides about one", %{conn: conn} do
      {:ok, tag} = Statuses.upsert_tag("gardening")

      assert [listed | _] = json_response(get(conn, "/api/v1/admin/tags"), 200)
      assert listed["name"] == "gardening"
      # Null, not false: nobody has decided yet, which is a third answer.
      assert listed["trendable"] == nil
      assert listed["requires_review"] == true

      shown = json_response(get(conn, "/api/v1/admin/tags/#{tag.id}"), 200)
      assert shown["id"] == to_string(tag.id)

      updated =
        json_response(
          put(conn, "/api/v1/admin/tags/#{tag.id}", %{"trendable" => "false", "usable" => "true"}),
          200
        )

      assert updated["trendable"] == false
      assert updated["usable"] == true
      # Reviewed either way: the queue is about somebody having looked.
      assert updated["requires_review"] == false
    end

    test "cannot be used to rename a tag out from under its posts", %{conn: conn} do
      {:ok, tag} = Statuses.upsert_tag("gardening")

      json_response(put(conn, "/api/v1/admin/tags/#{tag.id}", %{"name" => "somethingelse"}), 200)

      assert Repo.get(Abuuba.Statuses.Tag, tag.id).name == "gardening"
    end

    test "an id nobody has is a miss", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/admin/tags/999999"), 404)
    end
  end

  describe "the dashboard's numbers" do
    test "a measure is one value per day, with a total", %{conn: conn, moderator: moderator} do
      status_fixture(%{account_id: moderator.id})

      today = Date.utc_today() |> Date.to_iso8601()

      assert [measure] =
               json_response(
                 post(conn, "/api/v1/admin/measures", %{
                   "keys" => ["new_statuses"],
                   "start_at" => today,
                   "end_at" => today
                 }),
                 200
               )

      assert measure["key"] == "new_statuses"
      assert measure["total"] == "1"
      assert [%{"date" => _, "value" => "1"}] = measure["data"]
    end

    test "a key nobody defined is refused rather than drawn as zeroes", %{conn: conn} do
      # A chart of zeroes reads as a quiet week; a client asking for something
      # this server never heard of should find that out.
      body =
        json_response(
          post(conn, "/api/v1/admin/measures", %{"keys" => ["invented_metric"]}),
          422
        )

      assert body["error"] =~ "invented_metric"
    end

    test "a dimension is a breakdown, biggest first", %{conn: conn, moderator: moderator} do
      status_fixture(%{account_id: moderator.id, language: "de"})
      status_fixture(%{account_id: moderator.id, language: "de"})
      status_fixture(%{account_id: moderator.id, language: "en"})

      assert [dimension] =
               json_response(
                 post(conn, "/api/v1/admin/dimensions", %{"keys" => ["languages"]}),
                 200
               )

      assert dimension["key"] == "languages"

      assert [%{"key" => "de", "value" => "2"}, %{"key" => "en", "value" => "1"}] =
               dimension["data"]
    end

    test "a key this server cannot answer is an empty series, not an error", %{conn: conn} do
      # Nothing records a peer's version. A flat chart is an honest answer; a
      # missing series leaves the client waiting for something never coming.
      assert [%{"data" => []}] =
               json_response(
                 post(conn, "/api/v1/admin/dimensions", %{"keys" => ["software_versions"]}),
                 200
               )
    end

    test "retention says how much of a cohort stayed", %{conn: conn} do
      today = Date.utc_today() |> Date.to_iso8601()

      assert [cohort | _] =
               json_response(
                 get(conn, "/api/v1/admin/retention", %{
                   "start_at" => today,
                   "end_at" => today,
                   "frequency" => "day"
                 }),
                 200
               )

      assert cohort["period"]
      assert is_list(cohort["data"])
    end

    test "a window that is not a pair of dates is refused", %{conn: conn} do
      assert json_response(
               post(conn, "/api/v1/admin/measures", %{
                 "keys" => ["new_users"],
                 "start_at" => "not a date"
               }),
               422
             )
    end
  end

  describe "accounts" do
    test "deleting one takes the account and its posts with it", %{conn: conn} do
      target = account_fixture()
      status = status_fixture(%{account_id: target.id})

      body = json_response(delete(conn, "/api/v1/admin/accounts/#{target.id}"), 200)

      # The account as it was, so a client can show what it just removed.
      assert body["id"] == to_string(target.id)
      refute Repo.get(Account, target.id)
      refute Repo.get(Abuuba.Statuses.Status, status.id)
    end

    test "unsensitive lifts the mark", %{conn: conn} do
      target = account_fixture()

      {:ok, _} =
        Abuuba.Accounts.update_moderation(target, %{sensitized_at: DateTime.utc_now()})

      assert json_response(post(conn, "/api/v1/admin/accounts/#{target.id}/unsensitive"), 200)
      refute Repo.get(Account, target.id).sensitized_at
    end

    test "the v2 list answers the same as v1", %{conn: conn} do
      account_fixture()

      assert json_response(get(conn, "/api/v2/admin/accounts"), 200) ==
               json_response(get(conn, "/api/v1/admin/accounts"), 200)
    end
  end

  describe "reports" do
    test "a moderator can correct what one is filed under", %{conn: conn, moderator: moderator} do
      reporter = account_fixture()
      target = account_fixture()

      {:ok, report} =
        Reports.create(reporter, %{"target_account_id" => target.id, "comment" => "look at this"})

      updated =
        json_response(
          put(conn, "/api/v1/admin/reports/#{report.id}", %{"category" => "violation"}),
          200
        )

      assert updated["category"] == "violation"
      # The reporter's own words are not a moderator's to rewrite.
      assert updated["comment"] == "look at this"
      assert moderator
    end
  end

  describe "link publishers" do
    test "lists them and decides about one", %{conn: conn} do
      # A link only counts when the post carrying it could trend at all: public,
      # not a reply, not sensitive, by somebody findable.
      author = account_fixture(%{discoverable: true})
      status = status_fixture(%{account_id: author.id, visibility: "public"})
      Trends.record_link(status, "https://news.example/a-story")

      assert [publisher] = json_response(get(conn, "/api/v1/admin/trends/links/publishers"), 200)
      assert publisher["name"] == "news.example"
      assert publisher["trendable"] == nil

      assert json_response(
               post(conn, "/api/v1/admin/trends/links/publishers/news.example/reject"),
               200
             ) == %{}

      assert [%{"trendable" => false}] =
               json_response(get(conn, "/api/v1/admin/trends/links/publishers"), 200)
    end

    test "and approving one, which nothing covered", %{conn: conn} do
      # The other half of the pair. Worth saying plainly: neither this nor the
      # test above could have caught what was wrong here, because both touch
      # `Trends` first and that is what made the atom the controller was
      # building exist. A live server that had not touched trending yet
      # answered 500. The fix is to stop building the name at all.
      author = account_fixture(%{discoverable: true})
      status = status_fixture(%{account_id: author.id, visibility: "public"})
      Trends.record_link(status, "https://good.example/a-story")

      assert json_response(
               post(conn, "/api/v1/admin/trends/links/publishers/good.example/approve"),
               200
             ) == %{}

      assert [%{"trendable" => true}] =
               json_response(get(conn, "/api/v1/admin/trends/links/publishers"), 200)
    end

    test "an unknown decision is refused", %{conn: conn} do
      assert json_response(
               post(conn, "/api/v1/admin/trends/links/publishers/news.example/maybe"),
               422
             )
    end
  end

  describe "who may reach it" do
    test "a moderator with no permission is refused", %{plain: plain} do
      for path <- ["/api/v1/admin/tags", "/api/v2/admin/accounts"] do
        assert json_response(get(plain, path), 403), "reachable: #{path}"
      end

      assert json_response(post(plain, "/api/v1/admin/measures", %{"keys" => []}), 403)
    end
  end
end

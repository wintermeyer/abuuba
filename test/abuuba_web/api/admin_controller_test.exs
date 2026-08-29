defmodule AbuubaWeb.API.AdminControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.Domains
  alias Abuuba.Moderation.Reports
  alias Abuuba.Moderation.Signup
  alias Abuuba.OAuth
  alias Abuuba.Repo
  alias Abuuba.Roles

  defp token_for(permissions, position \\ 100) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: position,
        permissions: Roles.mask(permissions)
      })

    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, _} = Roles.assign(user, role)

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} =
      OAuth.issue_token(application, user, ["read", "write", "admin:read", "admin:write"])

    {account, raw}
  end

  defp as(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  setup %{conn: conn} do
    {moderator, raw} = token_for(~w(manage_users manage_reports manage_federation))

    %{conn: as(conn, raw), moderator: moderator, plain: conn}
  end

  describe "who may use it" do
    test "not a token without the permission", %{plain: plain} do
      {_account, raw} = token_for([])

      assert json_response(get(as(plain, raw), "/api/v1/admin/accounts"), 403)["error"]
    end

    test "not a stranger", %{plain: plain} do
      assert json_response(get(plain, "/api/v1/admin/accounts"), 422)["error"]
    end

    test "one permission does not carry another", %{plain: plain} do
      # A moderator who may read reports has not thereby been given the
      # federation controls.
      {_account, raw} = token_for(["manage_reports"])

      assert json_response(get(as(plain, raw), "/api/v1/admin/domain_blocks"), 403)["error"]
      assert json_response(get(as(plain, raw), "/api/v1/admin/reports"), 200)
    end
  end

  describe "accounts" do
    test "lists them with what only a moderator may see", %{conn: conn} do
      account = account_fixture(%{username: "listed"})
      user = user_fixture(%{account_id: account.id, approved: true})

      body = json_response(get(conn, "/api/v1/admin/accounts", %{"username" => "listed"}), 200)

      assert [entry] = body
      assert entry["username"] == "listed"
      assert entry["email"] == user.email
      assert entry["account"]["username"] == "listed"
      refute entry["account"]["email"]
    end

    test "page through them, because a moderator's tool cannot stop at the first screen" do
      # Without a cursor and a Link header there is no second page: a tool asks
      # once, gets the newest `limit` accounts, and has no way to learn that
      # there are more. On an instance of any size that is most of them.
      for i <- 1..3, do: account_fixture(%{username: "pager#{i}"})

      {_moderator, raw} = token_for(~w(manage_users))
      conn = as(build_conn(), raw)

      first = get(conn, "/api/v1/admin/accounts", %{"limit" => "2"})
      body = json_response(first, 200)

      assert length(body) == 2
      assert [link] = get_resp_header(first, "link")
      assert link =~ ~s(rel="next")

      # The oldest of the page is the cursor for the one after it.
      oldest = body |> List.last() |> Map.fetch!("id")

      next =
        json_response(
          get(conn, "/api/v1/admin/accounts", %{"limit" => "2", "max_id" => oldest}),
          200
        )

      assert next != []

      refute Enum.any?(next, &(&1["id"] == oldest)),
             "max_id is exclusive; a repeated row means a client loops forever"

      # Descending, which is what makes max_id mean "older than this".
      ids = Enum.map(body, & &1["id"])
      assert ids == Enum.sort(ids, :desc)
    end

    test "the block lists page too, and are bounded whatever is asked for", %{
      moderator: moderator
    } do
      # These three answered with the whole table. A shared blocklist runs to
      # thousands of rows, so the response grew with the list and there was no
      # second page because there was never a first.
      for i <- 1..3 do
        {:ok, _} = Signup.block_email_domain(moderator, %{"domain" => "spam#{i}.example"})
      end

      {_admin, raw} = token_for(~w(manage_blocks))

      response =
        get(as(build_conn(), raw), "/api/v1/admin/email_domain_blocks", %{"limit" => "2"})

      assert length(json_response(response, 200)) == 2
      assert [link] = get_resp_header(response, "link")
      assert link =~ ~s(rel="next")
    end

    test "and an admin screen still sees the whole list", %{moderator: moderator} do
      # The screens call these with no page at all, and that has to keep
      # meaning every row: quietly cutting them to a default limit would hide
      # entries from the person maintaining the list.
      for i <- 1..3 do
        {:ok, _} = Signup.block_email_domain(moderator, %{"domain" => "unpaged#{i}.example"})
      end

      assert length(Signup.email_domain_blocks()) == 3
    end

    test "and the last page says so by sending no link", %{conn: conn} do
      # A `next` pointing at nothing tells a client to keep asking.
      response = get(conn, "/api/v1/admin/accounts", %{"username" => "nobody-by-that-name"})

      assert json_response(response, 200) == []
      assert get_resp_header(response, "link") == []
    end

    test "one by id", %{conn: conn} do
      account = account_fixture()

      body = json_response(get(conn, "/api/v1/admin/accounts/#{account.id}"), 200)

      assert body["id"] == to_string(account.id)
    end

    test "404 for one that is not there", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/admin/accounts/999999999"), 404)["error"]
    end

    test "takes an action", %{conn: conn} do
      target = account_fixture()

      assert json_response(
               post(conn, "/api/v1/admin/accounts/#{target.id}/action", %{
                 "type" => "silence",
                 "text" => "Please stop."
               }),
               200
             )

      assert Accounts.get_account(target.id).silenced_at
      assert [%{text: "Please stop."}] = Actions.strikes(target)
    end

    test "translates Mastodon's name for marking posts sensitive", %{conn: conn} do
      target = account_fixture()

      post(conn, "/api/v1/admin/accounts/#{target.id}/action", %{"type" => "sensitive"})

      assert Accounts.get_account(target.id).sensitized_at
    end

    test "refuses an action against somebody who outranks you", %{plain: plain} do
      # The permission says what kind of work somebody does. Rank says who they
      # may do it to, and a token is exactly how that gets bypassed.
      {_junior, raw} = token_for(["manage_users"], 10)

      senior = account_fixture()
      senior_user = user_fixture(%{account_id: senior.id, approved: true})

      {:ok, role} =
        Roles.create(%{name: "Senior #{System.unique_integer([:positive])}", position: 900})

      {:ok, _} = Roles.assign(senior_user, role)

      conn =
        post(as(plain, raw), "/api/v1/admin/accounts/#{senior.id}/action", %{"type" => "suspend"})

      assert json_response(conn, 403)["error"]
      refute Accounts.get_account(senior.id).suspended_at
    end

    test "lets somebody in", %{conn: conn} do
      account = account_fixture()
      user = user_fixture(%{account_id: account.id, approved: false})

      assert json_response(post(conn, "/api/v1/admin/accounts/#{account.id}/approve"), 200)
      assert Repo.get(Abuuba.Accounts.User, user.id).approved
    end

    test "turns somebody away", %{conn: conn} do
      account = account_fixture()
      user = user_fixture(%{account_id: account.id, approved: false})

      assert json_response(post(conn, "/api/v1/admin/accounts/#{account.id}/reject"), 200)
      assert Repo.get(Abuuba.Accounts.User, user.id) == nil
    end

    test "lifts a silence without lifting a suspension", %{conn: conn, moderator: mod} do
      # A client that means to lift one must not lift the other.
      target = account_fixture()
      {:ok, _} = Actions.take(mod, target, "silence")
      {:ok, _} = Actions.take(mod, target, "suspend")

      assert json_response(post(conn, "/api/v1/admin/accounts/#{target.id}/unsilence"), 200)

      account = Accounts.get_account(target.id)

      refute account.silenced_at
      assert account.suspended_at
    end

    test "and a suspension on its own", %{conn: conn, moderator: mod} do
      target = account_fixture()
      {:ok, _} = Actions.take(mod, target, "suspend")

      assert json_response(post(conn, "/api/v1/admin/accounts/#{target.id}/unsuspend"), 200)

      account = Accounts.get_account(target.id)

      refute account.suspended_at
      refute account.purge_after
    end
  end

  describe "reports" do
    setup %{moderator: mod} do
      target = account_fixture()
      {:ok, report} = Reports.create(account_fixture(), %{"target_account_id" => target.id})

      %{report: report, target: target, moderator: mod}
    end

    test "lists what is open", %{conn: conn, report: report} do
      assert [entry] = json_response(get(conn, "/api/v1/admin/reports"), 200)

      assert entry["id"] == to_string(report.id)
      refute entry["action_taken"]
      assert entry["target_account"]["id"]
    end

    test "one by id", %{conn: conn, report: report} do
      body = json_response(get(conn, "/api/v1/admin/reports/#{report.id}"), 200)

      assert body["id"] == to_string(report.id)
    end

    test "resolving takes it off the queue", %{conn: conn, report: report} do
      assert json_response(post(conn, "/api/v1/admin/reports/#{report.id}/resolve"), 200)[
               "action_taken"
             ]

      assert Reports.open_count() == 0
    end

    test "and reopening puts it back", %{conn: conn, report: report} do
      post(conn, "/api/v1/admin/reports/#{report.id}/resolve")

      assert json_response(post(conn, "/api/v1/admin/reports/#{report.id}/reopen"), 200)

      assert Reports.open_count() == 1
    end

    test "taking one on and handing it back", %{conn: conn, report: report, moderator: mod} do
      body = json_response(post(conn, "/api/v1/admin/reports/#{report.id}/assign_to_self"), 200)

      assert body["assigned_account"]["id"] == to_string(mod.id)

      body = json_response(post(conn, "/api/v1/admin/reports/#{report.id}/unassign"), 200)

      assert body["assigned_account"] == nil
    end
  end

  describe "trends" do
    setup %{plain: plain} do
      {_account, raw} = token_for(["manage_taxonomies"])

      {:ok, _} = Abuuba.Statuses.upsert_tag("waiting")
      Abuuba.Trends.put_counts("tag", "waiting", Date.utc_today(), accounts: 30)

      %{trend_conn: as(plain, raw)}
    end

    test "lists what is waiting", %{trend_conn: conn} do
      body = json_response(get(conn, "/api/v1/admin/trends/tag", %{"pending" => "true"}), 200)

      assert [%{"subject" => "waiting"}] = body
    end

    test "and what is showing", %{trend_conn: conn} do
      post(conn, "/api/v1/admin/trends/tag/waiting/approve")
      :ok = Abuuba.Trends.rank()

      assert [%{"subject" => "waiting", "rank" => 1}] =
               json_response(get(conn, "/api/v1/admin/trends/tag"), 200)
    end

    test "approving lets it through", %{trend_conn: conn} do
      assert json_response(post(conn, "/api/v1/admin/trends/tag/waiting/approve"), 200)

      :ok = Abuuba.Trends.rank()

      assert [_] = Abuuba.Trends.list("tag")
    end

    test "refusing keeps it out", %{trend_conn: conn} do
      assert json_response(post(conn, "/api/v1/admin/trends/tag/waiting/reject"), 200)

      :ok = Abuuba.Trends.rank()

      assert Abuuba.Trends.list("tag") == []
    end

    test "refuses a kind nobody defined", %{trend_conn: conn} do
      assert json_response(get(conn, "/api/v1/admin/trends/weather"), 422)["error"]
    end

    test "needs the taxonomies permission", %{conn: conn} do
      # The moderator in the outer setup holds users, reports and federation.
      assert json_response(get(conn, "/api/v1/admin/trends/tag"), 403)["error"]
    end
  end

  describe "domain blocks" do
    test "writes one down", %{conn: conn} do
      body =
        json_response(
          post(conn, "/api/v1/admin/domain_blocks", %{
            "domain" => "bad.example",
            "severity" => "suspend",
            "private_comment" => "Reported by three people."
          }),
          200
        )

      assert body["domain"] == "bad.example"
      assert body["severity"] == "suspend"
      assert body["private_comment"] == "Reported by three people."
      assert Domains.suspended?("bad.example")
    end

    test "refuses one it cannot read", %{conn: conn} do
      assert json_response(
               post(conn, "/api/v1/admin/domain_blocks", %{
                 "domain" => "bad.example",
                 "severity" => "vanish"
               }),
               422
             )["error"]
    end

    test "lists them and reads one", %{conn: conn, moderator: mod} do
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example"})

      assert [entry] = json_response(get(conn, "/api/v1/admin/domain_blocks"), 200)
      assert entry["id"] == to_string(block.id)

      assert json_response(get(conn, "/api/v1/admin/domain_blocks/#{block.id}"), 200)["domain"] ==
               "bad.example"
    end

    test "changes one", %{conn: conn, moderator: mod} do
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "silence"})

      body =
        json_response(
          put(conn, "/api/v1/admin/domain_blocks/#{block.id}", %{"severity" => "suspend"}),
          200
        )

      assert body["severity"] == "suspend"
      assert Domains.suspended?("bad.example")
    end

    test "lifts one", %{conn: conn, moderator: mod} do
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example"})

      assert json_response(delete(conn, "/api/v1/admin/domain_blocks/#{block.id}"), 200)
      assert Domains.block_for("bad.example") == nil
    end
  end
end

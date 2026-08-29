defmodule AbuubaWeb.AdminLiveTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Admin
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.Reports
  alias Abuuba.Moderation.Signup
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings

  defp signed_in_with(conn, permissions) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 100,
        permissions: Roles.mask(permissions)
      })

    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, user} = Roles.assign(user, role)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))

    %{conn: conn, account: account, user: user}
  end

  defp pending_user do
    account = account_fixture(%{username: "hopeful#{System.unique_integer([:positive])}"})

    user_fixture(%{account_id: account.id, approved: false, confirmed_at: DateTime.utc_now()})
  end

  describe "getting in" do
    test "somebody with no admin permission cannot", %{conn: conn} do
      %{conn: conn} = signed_in_with(conn, [])

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end

    test "somebody with one can", %{conn: conn} do
      %{conn: conn} = signed_in_with(conn, ["view_dashboard"])

      assert {:ok, _live, html} = live(conn, ~p"/admin")
      assert html =~ "Dashboard"
    end

    test "a signed-out visitor is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login" <> _}}} = live(conn, ~p"/admin")
    end

    test "a section somebody may not use is not offered", %{conn: conn} do
      # Showing a link that answers "not allowed" is a worse answer than not
      # showing the link.
      %{conn: conn} = signed_in_with(conn, ["view_dashboard"])

      {:ok, _live, html} = live(conn, ~p"/admin")

      refute html =~ ~p"/admin/settings"
    end

    test "and cannot be reached by typing its address", %{conn: conn} do
      %{conn: conn} = signed_in_with(conn, ["view_dashboard"])

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/admin/settings")
    end
  end

  describe "the dashboard" do
    setup %{conn: conn} do
      signed_in_with(conn, ["view_dashboard", "manage_users"])
    end

    test "says how much work is waiting", %{conn: conn, account: mod} do
      target = account_fixture()

      {:ok, _} =
        Reports.create(account_fixture(), %{"target_account_id" => target.id})

      {:ok, strike} = Actions.take(mod, target, "silence")
      {:ok, _} = Actions.appeal(target, strike, "I did not.")

      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ "Reports waiting"
      assert html =~ "Appeals waiting"
    end

    test "says what is wrong", %{conn: conn} do
      :ok = Settings.put_registration_mode("open")

      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ "Anybody may sign up"
    end
  end

  describe "accounts" do
    setup %{conn: conn} do
      signed_in_with(conn, ["view_dashboard", "manage_users", "manage_roles"])
    end

    test "lists them and finds one by name", %{conn: conn} do
      account_fixture(%{username: "searchable"})

      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      html = live |> form("#account-search", %{"query" => "search"}) |> render_submit()

      assert html =~ "searchable"
    end

    test "shows what an applicant wrote about why they want to join", %{conn: conn} do
      # The question is only worth asking if the moderator deciding on the
      # account can read the answer.
      user = pending_user()

      {:ok, _} =
        user
        |> Ecto.Changeset.change(sign_up_reason: "I run the local cycling club")
        |> Repo.update()

      {:ok, _live, html} = live(conn, ~p"/admin/accounts?status=pending")

      assert html =~ "I run the local cycling club"
    end

    test "marks an account as a memorial and back again", %{conn: conn} do
      subject = account_fixture()
      user = user_fixture(%{account_id: subject.id, approved: true})

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{subject.id}")

      live |> element("button[phx-click='memorialize']") |> render_click()

      assert Repo.get(Account, subject.id).memorial
      # It stops the login. That is the whole of what it does besides the mark.
      assert User.disabled?(Repo.reload!(user))
      refute Repo.get(Account, subject.id).suspended_at

      live |> element("button[phx-click='memorialize']") |> render_click()

      refute Repo.get(Account, subject.id).memorial
    end

    test "lets somebody in", %{conn: conn} do
      user = pending_user()

      {:ok, live, _html} = live(conn, ~p"/admin/accounts?status=pending")

      live
      |> element("button[phx-click='approve'][phx-value-user='#{user.id}']")
      |> render_click()

      assert Repo.get(Abuuba.Accounts.User, user.id).approved
    end

    test "turns somebody away", %{conn: conn} do
      user = pending_user()

      {:ok, live, _html} = live(conn, ~p"/admin/accounts?status=pending")

      live
      |> element("button[phx-click='reject'][phx-value-user='#{user.id}']")
      |> render_click()

      assert Repo.get(Abuuba.Accounts.User, user.id) == nil
    end

    test "shows one account with what can be done to it", %{conn: conn} do
      target = account_fixture(%{username: "underreview"})

      {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{target.id}")

      assert html =~ "underreview"
      assert html =~ "Silence"
    end

    test "takes an action against it", %{conn: conn} do
      target = account_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{target.id}")

      live
      |> form("#action-form", %{"action" => "silence", "text" => "Please stop."})
      |> render_submit()

      assert Abuuba.Accounts.get_account(target.id).silenced_at
      assert [%{action: "silence", text: "Please stop."}] = Actions.strikes(target)
    end

    test "and lifts one", %{conn: conn, account: mod} do
      target = account_fixture()
      {:ok, strike} = Actions.take(mod, target, "silence")

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{target.id}")

      live
      |> element("button[phx-click='undo'][phx-value-strike='#{strike.id}']")
      |> render_click()

      refute Abuuba.Accounts.get_account(target.id).silenced_at
    end

    test "gives somebody a role", %{conn: conn} do
      user = pending_user()
      {:ok, role} = Roles.create(%{name: "Helper", position: 10})

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{user.account_id}")

      live |> form("#role-form", %{"role" => to_string(role.id)}) |> render_submit()

      assert Repo.get(Abuuba.Accounts.User, user.id).role_id == role.id
    end

    test "changes an email address", %{conn: conn} do
      user = pending_user()

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{user.account_id}")

      live |> form("#email-form", %{"email" => "moved@example.test"}) |> render_submit()

      assert Repo.get(Abuuba.Accounts.User, user.id).email == "moved@example.test"
    end

    test "refuses to act on somebody who outranks you", %{conn: conn} do
      # Otherwise two moderators can unmake each other, which is a fight rather
      # than a hierarchy.
      {:ok, senior_role} =
        Roles.create(%{name: "Senior", position: 500, permissions: Roles.mask(["administrator"])})

      senior = account_fixture()

      senior_user =
        user_fixture(%{account_id: senior.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, _} = Roles.assign(senior_user, senior_role)

      {:ok, live, html} = live(conn, ~p"/admin/accounts/#{senior.id}")

      refute html =~ "id=\"action-form\""

      html =
        live
        |> render_hook("act", %{"action" => "suspend", "text" => ""})

      assert html =~ "outranks"
      refute Abuuba.Accounts.get_account(senior.id).suspended_at
    end
  end

  describe "trends" do
    setup %{conn: conn} do
      signed_in_with(conn, ["view_dashboard", "manage_taxonomies"])
    end

    test "lists what is waiting to be looked at", %{conn: conn} do
      {:ok, _} = Abuuba.Statuses.upsert_tag("waiting")
      Abuuba.Trends.put_counts("tag", "waiting", Date.utc_today(), accounts: 30)

      {:ok, _live, html} = live(conn, ~p"/admin/trends")

      assert html =~ "waiting"
      assert html =~ "Allow"
    end

    test "allowing one puts it in the list", %{conn: conn} do
      {:ok, _} = Abuuba.Statuses.upsert_tag("fine")
      Abuuba.Trends.put_counts("tag", "fine", Date.utc_today(), accounts: 30)

      {:ok, live, _html} = live(conn, ~p"/admin/trends")

      live
      |> element("button[phx-click='approve_trend'][phx-value-subject='fine']")
      |> render_click()

      :ok = Abuuba.Trends.rank()

      assert [%{subject: "fine"}] = Abuuba.Trends.list("tag")
    end

    test "refusing one keeps it out", %{conn: conn} do
      {:ok, tag} = Abuuba.Statuses.upsert_tag("nope")
      Abuuba.Trends.put_counts("tag", "nope", Date.utc_today(), accounts: 30)

      {:ok, live, _html} = live(conn, ~p"/admin/trends")

      live
      |> element("button[phx-click='reject_trend'][phx-value-subject='nope']")
      |> render_click()

      refute Repo.reload(tag).trendable
    end

    test "is not offered to somebody without the permission", %{conn: conn} do
      %{conn: conn} = signed_in_with(conn, ["view_dashboard"])

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/admin/trends")
    end
  end

  describe "announcements" do
    setup %{conn: conn} do
      signed_in_with(conn, ["view_dashboard", "manage_announcements"])
    end

    test "writing one publishes it straight away", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/announcements")

      live
      |> form("#announcement-form", %{
        "text" => "The server moves on Sunday.",
        "scheduled_at" => ""
      })
      |> render_submit()

      assert [%{text: "The server moves on Sunday."}] = Abuuba.Instance.announcements()
    end

    test "giving it a time leaves it for later", %{conn: conn} do
      # An admin writing on Thursday about Sunday should not have to be awake
      # on Sunday.
      {:ok, live, _html} = live(conn, ~p"/admin/announcements")

      later =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()
        |> String.slice(0, 16)

      live
      |> form("#announcement-form", %{"text" => "Later.", "scheduled_at" => later})
      |> render_submit()

      assert Abuuba.Instance.announcements() == []

      assert [%{published: false, scheduled_at: %DateTime{}}] =
               Abuuba.Instance.all_announcements()
    end

    test "and one can be taken down", %{conn: conn} do
      {:ok, announcement} = Abuuba.Instance.create_announcement(%{text: "Oops", published: true})

      {:ok, live, _html} = live(conn, ~p"/admin/announcements")

      live
      |> element(
        "button[phx-click='delete_announcement'][phx-value-announcement='#{announcement.id}']"
      )
      |> render_click()

      assert Abuuba.Instance.all_announcements() == []
    end
  end

  describe "sign-up blocks" do
    setup %{conn: conn} do
      signed_in_with(conn, ["view_dashboard", "manage_blocks"])
    end

    test "a mail domain can be blocked and lifted", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/signups")

      html =
        live
        |> form("#email-domain-form", %{"domain" => "spam.example"})
        |> render_submit()

      assert html =~ "spam.example"
      assert [block] = Signup.email_domain_blocks()

      live
      |> element("button[phx-value-kind='email_domain'][phx-value-id='#{block.id}']")
      |> render_click()

      assert Signup.email_domain_blocks() == []
    end

    test "an address range with a severity", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/signups")

      live
      |> form("#ip-form", %{"cidr" => "203.0.113.0/24", "severity" => "no_access"})
      |> render_submit()

      assert [%{severity: "no_access"}] = Signup.ip_blocks()
    end

    test "a range nobody can read says so rather than saving it", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/signups")

      html =
        live
        |> form("#ip-form", %{"cidr" => "not an address", "severity" => "sign_up_block"})
        |> render_submit()

      assert html =~ "could not be saved"
      assert Signup.ip_blocks() == []
    end

    test "a username, anywhere in a name", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/signups")

      live
      |> form("#username-form", %{"username" => "support", "partial" => "true"})
      |> render_submit()

      assert [%{username: "support", exact: false}] = Signup.username_blocks()
    end

    test "is not offered without the permission", %{conn: conn} do
      %{conn: conn} = signed_in_with(conn, ["view_dashboard"])

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/admin/signups")
    end
  end

  describe "settings" do
    setup %{conn: conn} do
      signed_in_with(conn, ["view_dashboard", "manage_settings"])
    end

    test "shows what is set", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/settings")

      assert html =~ "site_title" or html =~ "Server name"
    end

    test "adds a rule and takes one away", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/settings")

      live |> form("#rule-form", %{"text" => "Be kind to each other."}) |> render_submit()

      assert [rule] = Settings.rules()
      assert rule.text == "Be kind to each other."

      live
      |> element("button[phx-click='delete_rule'][phx-value-rule='#{rule.id}']")
      |> render_click()

      assert Settings.rules() == []
    end

    test "publishes a version of the terms", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/settings")

      live
      |> form("#terms-form", %{
        "text" => "Do not do anything illegal.",
        "effective_date" => Date.to_iso8601(Date.utc_today())
      })
      |> render_submit()

      assert Abuuba.Instance.current_terms().text == "Do not do anything illegal."
    end

    test "and can tell everybody about it", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/settings")

      live
      |> form("#terms-form", %{
        "text" => "New terms",
        "effective_date" => Date.to_iso8601(Date.utc_today())
      })
      |> render_submit()

      terms = Abuuba.Instance.current_terms()

      live
      |> element("button[phx-click='announce_terms'][phx-value-terms='#{terms.id}']")
      |> render_click()

      assert Abuuba.Repo.reload(terms).notified_at
      assert [_] = Abuuba.Instance.announcements()
    end

    test "saves a change", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/settings")

      live
      |> form("#settings-form", %{
        "site_title" => "A Better Name",
        "registration_mode" => "closed"
      })
      |> render_submit()

      assert Settings.get("site_title") == "A Better Name"
      assert Settings.registration_mode() == :closed
    end
  end

  describe "the audit log" do
    setup %{conn: conn} do
      signed_in_with(conn, ["view_dashboard", "view_audit_log"])
    end

    test "says who did what to whom", %{conn: conn, account: mod} do
      target = account_fixture(%{username: "actedupon"})
      {:ok, _} = Actions.take(mod, target, "silence")

      {:ok, _live, html} = live(conn, ~p"/admin/audit-log")

      assert html =~ "actedupon"
      assert html =~ "account.silence"
    end

    test "still says it after the account is gone", %{conn: conn, account: mod} do
      target = account_fixture(%{username: "gonesoon"})
      {:ok, _} = Actions.take(mod, target, "silence")
      {:ok, _} = Abuuba.Accounts.delete_account(target)

      {:ok, _live, html} = live(conn, ~p"/admin/audit-log")

      assert html =~ "gonesoon"
    end

    test "can be narrowed to one action", %{conn: conn, account: mod} do
      {:ok, _} = Actions.take(mod, account_fixture(%{username: "silenced1"}), "silence")
      {:ok, _} = Actions.take(mod, account_fixture(%{username: "suspended1"}), "suspend")

      {:ok, live, _html} = live(conn, ~p"/admin/audit-log")

      html = live |> form("#audit-filter", %{"action" => "account.suspend"}) |> render_submit()

      assert html =~ "suspended1"
      refute html =~ "silenced1"
    end
  end

  describe "what the context is asked" do
    test "the settings list only carries known keys" do
      assert "site_title" in Admin.settings_keys()
      refute "wallet_key" in Admin.settings_keys()
    end
  end
end

defmodule AbuubaWeb.AdminReportsTest do
  @moduledoc """
  The report queue, batch actions over a filtered list, and warning presets.

  Every "this is refused" here is paired with the same thing succeeding for
  somebody entitled to it. A suite of refusals alone passes just as happily
  against a screen that refuses everybody.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.Report
  alias Abuuba.Moderation.Reports
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings

  setup %{conn: conn} do
    moderator = staff(["manage_users", "manage_reports", "manage_settings"])

    reporter = account_fixture(%{username: "complainer"})
    target = account_fixture(%{username: "trouble"})
    status = status_fixture(%{account_id: target.id, text: "the offending post"})

    {:ok, report} =
      Reports.create(reporter, %{
        "target_account_id" => target.id,
        "comment" => "This is not on",
        "status_ids" => [to_string(status.id)]
      })

    %{
      conn: log_in(conn, moderator),
      moderator: moderator,
      moderator_account: Accounts.get_account(moderator.account_id),
      reporter: reporter,
      target: target,
      report: report,
      status: status
    }
  end

  defp staff(permissions) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 900,
        permissions: Roles.mask(permissions)
      })

    user =
      user_fixture(%{
        account_id: account_fixture().id,
        approved: true,
        confirmed_at: DateTime.utc_now()
      })

    {:ok, user} = Roles.assign(user, role)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "the report queue" do
    test "lists what is waiting", %{conn: conn, report: report} do
      {:ok, _live, html} = live(conn, ~p"/admin/reports")

      assert html =~ "trouble"
      assert html =~ "complainer"
      assert html =~ to_string(report.id)
    end

    test "shows the open ones by default and the rest on asking", %{
      conn: conn,
      report: report,
      moderator_account: moderator
    } do
      {:ok, _resolved} = Reports.resolve(report, moderator)

      {:ok, live, html} = live(conn, ~p"/admin/reports")

      # A queue that shows everything ever filed is a queue nobody works.
      refute html =~ "trouble"

      html = live |> element("#report-filter") |> render_change(%{"state" => "resolved"})

      assert html =~ "trouble"
    end

    test "refuses a moderator without the permission", %{conn: _conn} do
      plain = log_in(build_conn(), staff(["manage_users"]))

      assert {:error, {:live_redirect, _}} = live(plain, ~p"/admin/reports")
    end
  end

  describe "one report" do
    test "shows what was said and what it names", %{conn: conn, report: report} do
      {:ok, _live, html} = live(conn, ~p"/admin/reports/#{report.id}")

      assert html =~ "This is not on"
      assert html =~ "the offending post"
      assert html =~ "trouble"
    end

    test "is taken and resolved", %{conn: conn, report: report, moderator_account: moderator} do
      {:ok, live, _html} = live(conn, ~p"/admin/reports/#{report.id}")

      live |> element("button[phx-click='assign_report']") |> render_click()
      assert Repo.reload!(report).assigned_account_id == moderator.id

      live |> element("button[phx-click='resolve_report']") |> render_click()
      assert Repo.reload!(report).action_taken_at
    end

    test "is reopened when it was closed too soon", %{
      conn: conn,
      report: report,
      moderator_account: moderator
    } do
      {:ok, _resolved} = Reports.resolve(report, moderator)

      {:ok, live, _html} = live(conn, ~p"/admin/reports/#{report.id}")

      live |> element("button[phx-click='reopen_report']") |> render_click()

      refute Repo.reload!(report).action_taken_at
    end
  end

  describe "notes on a report" do
    test "are kept and shown to the next moderator", %{conn: conn, report: report} do
      {:ok, live, _html} = live(conn, ~p"/admin/reports/#{report.id}")

      html =
        live
        |> form("#report-note-form", %{"note" => "Checked the other three, same person"})
        |> render_submit()

      assert html =~ "Checked the other three, same person"

      assert [%{content: "Checked the other three, same person"}] =
               Actions.notes(:report, report.id)
    end

    test "say who wrote them", %{conn: conn, report: report, moderator: moderator} do
      {:ok, live, _html} = live(conn, ~p"/admin/reports/#{report.id}")

      html = live |> form("#report-note-form", %{"note" => "Mine"}) |> render_submit()

      assert html =~ Accounts.get_account(moderator.account_id).username
    end

    test "are not written by somebody who may not moderate", %{report: report} do
      plain = log_in(build_conn(), staff(["manage_users"]))

      assert {:error, {:live_redirect, _}} = live(plain, ~p"/admin/reports/#{report.id}")
      assert Actions.notes(:report, report.id) == []
    end

    test "ignore an empty one", %{conn: conn, report: report} do
      {:ok, live, _html} = live(conn, ~p"/admin/reports/#{report.id}")

      live |> form("#report-note-form", %{"note" => "   "}) |> render_submit()

      assert Actions.notes(:report, report.id) == []
    end
  end

  describe "what a moderator may send, as opposed to open" do
    test "a reports-only moderator cannot rewrite the server settings", %{report: report} do
      # The section gate decides which screens somebody may open. It says
      # nothing about which events they may send, and an event comes from
      # whatever is on the other end of the socket rather than from the page
      # that was rendered.
      moderator = log_in(build_conn(), staff(["manage_reports"]))

      {:ok, live, _html} = live(moderator, ~p"/admin/reports/#{report.id}")

      render_submit(live, "save_settings", %{"site_title" => "pwned"})

      assert Settings.get("site_title") != "pwned"
    end

    test "nor approve somebody waiting to be let in", %{report: report} do
      moderator = log_in(build_conn(), staff(["manage_reports"]))
      waiting = user_fixture(%{account_id: account_fixture().id, approved: false})

      {:ok, live, _html} = live(moderator, ~p"/admin/reports/#{report.id}")

      render_click(live, "approve", %{"user" => to_string(waiting.id)})

      refute Repo.reload!(waiting).approved
    end

    test "and can still do the thing they are for", %{report: report} do
      # The positive control. Every refusal above passes just as happily
      # against a gate that refuses everybody.
      moderator = log_in(build_conn(), staff(["manage_reports"]))

      {:ok, live, _html} = live(moderator, ~p"/admin/reports/#{report.id}")

      live |> form("#report-note-form", %{"note" => "Mine to write"}) |> render_submit()

      assert [%{content: "Mine to write"}] = Actions.notes(:report, report.id)
    end

    test "an event nobody declared is refused rather than allowed", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      # Default-deny: an event added without a permission beside it must not
      # be reachable, because the other way round is a hole nobody notices.
      html = render_click(live, "not_a_real_event", %{})

      assert html =~ "may not do that"
    end
  end

  describe "acting on several accounts at once" do
    setup do
      %{
        one: account_fixture(%{username: "noisy_one"}),
        two: account_fixture(%{username: "noisy_two"})
      }
    end

    test "says nothing about rank when nothing was skipped", %{conn: conn, one: one} do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      html =
        live
        |> form("#batch-form", %{
          "accounts" => %{to_string(one.id) => "true"},
          "action" => "silence"
        })
        |> render_submit()

      refute html =~ "outranks"
    end

    test "silences everyone that was ticked", %{conn: conn, one: one, two: two} do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      live
      |> form("#batch-form", %{
        "accounts" => %{to_string(one.id) => "true", to_string(two.id) => "true"},
        "action" => "silence"
      })
      |> render_submit()

      assert Repo.reload!(one).silenced_at
      assert Repo.reload!(two).silenced_at
    end

    test "leaves the ones nobody ticked alone", %{conn: conn, one: one, two: two} do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      live
      |> form("#batch-form", %{
        "accounts" => %{to_string(one.id) => "true"},
        "action" => "silence"
      })
      |> render_submit()

      assert Repo.reload!(one).silenced_at
      refute Repo.reload!(two).silenced_at
    end

    test "writes an audit entry for each account, not one for the batch", %{
      conn: conn,
      one: one,
      two: two
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      live
      |> form("#batch-form", %{
        "accounts" => %{to_string(one.id) => "true", to_string(two.id) => "true"},
        "action" => "silence"
      })
      |> render_submit()

      # "Who silenced this account" has to stay answerable per account.
      assert length(AuditLog.for_target(:account, one.id)) == 1
      assert length(AuditLog.for_target(:account, two.id)) == 1
    end

    test "says how many and what, before doing it", %{conn: conn, one: one, two: two} do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      html = render_change(live, "pick_batch", %{"accounts" => %{to_string(one.id) => "true"}})

      # A confirmation that only says "are you sure" is one nobody reads.
      assert html =~ "One account ticked"
      assert html =~ "does the same thing to one account"
      refute Repo.reload!(one).silenced_at

      html =
        render_change(live, "pick_batch", %{
          "accounts" => %{to_string(one.id) => "true", to_string(two.id) => "true"}
        })

      assert html =~ "2 accounts ticked"
      assert html =~ "to all 2 accounts"
    end

    test "does what was chosen rather than always the same thing", %{conn: conn, one: one} do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      live
      |> form("#batch-form", %{
        "accounts" => %{to_string(one.id) => "true"},
        "action" => "suspend"
      })
      |> render_submit()

      one = Repo.reload!(one)
      assert one.suspended_at
      refute one.silenced_at
    end

    test "refuses an action the bar does not offer", %{conn: conn, one: one} do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      # Deleting posts cannot be undone, which is why it is not on the list.
      # A crafted event must not reach it either.
      html =
        render_submit(live, "batch", %{
          "accounts" => %{to_string(one.id) => "true"},
          "action" => "mark_statuses_as_sensitive"
        })

      assert html =~ "not something this list can do"
      refute Repo.reload!(one).sensitized_at
    end

    test "leaves an account the filter had hidden alone", %{conn: conn, one: one} do
      # The page shows nothing, so the batch may do nothing: an event carries
      # whatever it was sent with, and a moderator can only mean the accounts
      # they were looking at.
      {:ok, live, html} = live(conn, ~p"/admin/accounts?query=nothing_matches_this")
      refute html =~ "noisy_one"

      render_submit(live, "batch", %{
        "accounts" => %{to_string(one.id) => "true"},
        "action" => "suspend"
      })

      refute Repo.reload!(one).suspended_at
    end

    test "does not blame rank for a failure that was not about rank", %{conn: conn} do
      # An account that is already suspended cannot be suspended again, and
      # saying "it outranks yours" about it sends a moderator looking for a
      # permission problem that is not there.
      already = account_fixture(%{username: "already_gone"})
      {:ok, _} = Actions.take(Accounts.get_account(account_fixture().id), already, "suspend")

      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      html =
        live
        |> form("#batch-form", %{
          "accounts" => %{to_string(already.id) => "true"},
          "action" => "suspend"
        })
        |> render_submit()

      refute html =~ "outranks"
    end

    test "skips an account that outranks the moderator, and says so", %{conn: conn, one: one} do
      boss = staff(["manage_users"])
      boss_account = Accounts.get_account(boss.account_id)

      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      html =
        live
        |> form("#batch-form", %{
          "accounts" => %{
            to_string(one.id) => "true",
            to_string(boss_account.id) => "true"
          },
          "action" => "silence"
        })
        |> render_submit()

      refute Repo.reload!(boss_account).silenced_at
      assert html =~ "One account was left alone because it outranks yours"

      # The positive control: the one they were allowed to touch was touched.
      assert Repo.reload!(one).silenced_at
    end

    test "does nothing when nothing was ticked", %{conn: conn, one: one} do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts")

      live |> form("#batch-form", %{"accounts" => %{}, "action" => "silence"}) |> render_submit()

      refute Repo.reload!(one).silenced_at
    end
  end

  describe "warning presets" do
    setup do
      on_exit(fn -> Settings.put("warning_presets", []) end)

      :ok
    end

    test "are written in the settings and offered when acting", %{conn: conn, target: target} do
      {:ok, live, _html} = live(conn, ~p"/admin/settings")

      live
      |> form("#warning-preset-form", %{
        "preset" => %{"title" => "Spam", "text" => "Please stop posting adverts."}
      })
      |> render_submit()

      assert [%{"title" => "Spam"}] = Settings.get("warning_presets")

      {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{target.id}")
      assert html =~ "Spam"
    end

    test "fill the message in, still editable", %{conn: conn, target: target} do
      Settings.put("warning_presets", [
        %{"title" => "Spam", "text" => "Please stop posting adverts."}
      ])

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{target.id}")

      html = render_change(live, "pick_preset", %{"preset" => "Spam"})

      assert html =~ "Please stop posting adverts."
    end

    test "are removed", %{conn: conn} do
      Settings.put("warning_presets", [%{"title" => "Spam", "text" => "Stop."}])

      {:ok, live, _html} = live(conn, ~p"/admin/settings")

      live
      |> element("button[phx-click='delete_preset'][phx-value-title='Spam']")
      |> render_click()

      assert Settings.get("warning_presets") == []
    end

    test "refuse an empty one", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/settings")

      live
      |> form("#warning-preset-form", %{"preset" => %{"title" => "", "text" => ""}})
      |> render_submit()

      assert Settings.get("warning_presets") == []
    end

    test "reach the account they are used on", %{conn: conn, target: target} do
      Settings.put("warning_presets", [
        %{"title" => "Spam", "text" => "Please stop posting adverts."}
      ])

      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{target.id}")

      render_change(live, "pick_preset", %{"preset" => "Spam"})

      live
      |> form("#action-form", %{"action" => "silence", "text" => "Please stop posting adverts."})
      |> render_submit()

      assert [strike] = Actions.strikes(target)
      assert strike.text == "Please stop posting adverts."
    end
  end

  describe "the report a moderator has open" do
    test "counts towards the queue badge until it is resolved", %{
      report: report,
      moderator_account: moderator
    } do
      assert Reports.open_count() == 1

      {:ok, _resolved} = Reports.resolve(report, moderator)

      assert Reports.open_count() == 0
    end

    test "is fetched by id", %{report: report} do
      assert %Report{} = Reports.get(report.id)
    end
  end
end

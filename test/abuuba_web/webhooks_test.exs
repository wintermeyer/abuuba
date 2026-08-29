defmodule AbuubaWeb.WebhooksTest do
  use AbuubaWeb.ConnCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Moderation.Reports
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Webhooks
  alias Abuuba.Webhooks.Delivery
  alias Abuuba.Webhooks.Webhook

  setup %{conn: conn} do
    %{conn: log_in(conn, admin(["manage_webhooks"]))}
  end

  defp admin(permissions) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 100,
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

  defp webhook_fixture(events \\ ["report.created"]) do
    {:ok, webhook} =
      Webhooks.create(%{
        url: "https://example.com/hook#{System.unique_integer([:positive])}",
        events: events
      })

    webhook
  end

  describe "creating one" do
    test "is off until somebody turns it on" do
      webhook = webhook_fixture()

      # A URL typed wrong should be correctable before this server starts
      # posting somebody's reports to it.
      refute webhook.enabled
      assert webhook.secret
    end

    test "refuses an address that is not https" do
      assert {:error, changeset} = Webhooks.create(%{url: "http://example.com/hook", events: []})
      assert Keyword.has_key?(changeset.errors, :url)
    end

    test "refuses an event this server never sends" do
      # Silently keeping the ones it recognised would leave an admin watching
      # for something that will never arrive, with nothing saying so.
      assert {:error, changeset} =
               Webhooks.create(%{url: "https://example.com/h", events: ["account.exploded"]})

      assert Keyword.has_key?(changeset.errors, :events)
    end
  end

  describe "the secret" do
    test "changes on rotation, and the old one stops working" do
      webhook = webhook_fixture()
      {:ok, rotated} = Webhooks.rotate_secret(webhook)

      refute rotated.secret == webhook.secret
    end

    test "signs the exact body a receiver will check" do
      body = ~s({"event":"report.created"})

      assert Webhooks.signature("s3cret", body) =~ ~r/^sha256=[0-9a-f]{64}$/
      refute Webhooks.signature("s3cret", body) == Webhooks.signature("other", body)
    end
  end

  describe "announcing" do
    test "queues to every enabled webhook that asked for the event" do
      wanted = webhook_fixture(["report.created"])
      {:ok, wanted} = Webhooks.set_enabled(wanted, true)

      other = webhook_fixture(["status.created"])
      {:ok, _other} = Webhooks.set_enabled(other, true)

      _off = webhook_fixture(["report.created"])

      Webhooks.announce("report.created", %{"id" => "1"})

      ids =
        Oban.Job
        |> Repo.all()
        |> Enum.filter(&(&1.worker == "Abuuba.Webhooks.Worker"))
        |> Enum.map(&get_in(&1.args, ["webhook_id"]))

      # Only the one that is on and asked for it.
      assert ids == [wanted.id]
    end

    test "a report arriving is announced", %{} do
      webhook = webhook_fixture(["report.created"])
      {:ok, _on} = Webhooks.set_enabled(webhook, true)

      reporter = account_fixture()
      target = account_fixture()

      {:ok, _report} =
        Reports.create(reporter, %{"target_account_id" => target.id, "comment" => "spam"})

      assert Enum.any?(Repo.all(Oban.Job), fn job ->
               job.worker == "Abuuba.Webhooks.Worker" and
                 get_in(job.args, ["event"]) == "report.created"
             end)
    end

    test "a post being made is announced" do
      webhook = webhook_fixture(["status.created"])
      {:ok, _on} = Webhooks.set_enabled(webhook, true)

      status_fixture(%{account_id: account_fixture().id, text: "hello"})

      assert Enum.any?(Repo.all(Oban.Job), fn job ->
               job.worker == "Abuuba.Webhooks.Worker" and
                 get_in(job.args, ["event"]) == "status.created"
             end)
    end

    test "a profile being edited is announced" do
      webhook = webhook_fixture(["account.updated"])
      {:ok, _on} = Webhooks.set_enabled(webhook, true)

      account = account_fixture()
      {:ok, _} = Accounts.update_profile(account, %{"display_name" => "A new name"})

      assert queued?("account.updated")
    end

    test "and so is a moderator acting on somebody" do
      webhook = webhook_fixture(["account.updated"])
      {:ok, _on} = Webhooks.set_enabled(webhook, true)

      account = account_fixture()

      {:ok, _} = Accounts.update_moderation(account, %{silenced_at: DateTime.utc_now()})

      assert queued?("account.updated")
    end

    test "but another server's profile changing is not" do
      # We refetch remote actors on a schedule, and a moderation tool watching
      # this server does not want a stream of other people's profile churn.
      webhook = webhook_fixture(["account.updated"])
      {:ok, _on} = Webhooks.set_enabled(webhook, true)

      remote = remote_account_fixture(%{username: "elsewhere", domain: "other.example"})
      {:ok, _} = Accounts.update_account(remote, %{display_name: "Renamed"})

      refute queued?("account.updated")
    end

    test "carries the post's address rather than its words" do
      webhook = webhook_fixture(["status.created"])
      {:ok, _on} = Webhooks.set_enabled(webhook, true)

      status_fixture(%{account_id: account_fixture().id, text: "something private-ish"})

      job = Repo.all(Oban.Job) |> Enum.find(&(&1.worker == "Abuuba.Webhooks.Worker"))

      # A webhook body is a copy of somebody's writing sitting in somebody
      # else's logs. A receiver that wants the words can fetch them.
      refute inspect(job.args) =~ "private-ish"
      assert get_in(job.args, ["payload", "id"])
    end
  end

  defp queued?(event) do
    Enum.any?(Repo.all(Oban.Job), fn job ->
      job.worker == "Abuuba.Webhooks.Worker" and get_in(job.args, ["event"]) == event
    end)
  end

  describe "the delivery log" do
    test "records what happened, and says when it stopped working" do
      webhook = webhook_fixture()

      :ok = Webhooks.record(webhook, "report.created", status: 200)
      :ok = Webhooks.record(webhook, "report.created", status: 500, error: "server error")

      assert [latest, first] = Webhooks.deliveries(webhook)
      assert latest.status == 500
      assert first.status == 200
      refute Delivery.delivered?(latest)
      assert Delivery.delivered?(first)
    end

    test "is swept once it is old enough" do
      webhook = webhook_fixture()
      :ok = Webhooks.record(webhook, "report.created", status: 200)

      Delivery
      |> Repo.all()
      |> Enum.each(fn row ->
        row
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(DateTime.utc_now(), -Webhooks.keep_days() - 1, :day)
        )
        |> Repo.update!()
      end)

      assert Webhooks.sweep() == 1
      assert Webhooks.deliveries(webhook) == []
    end
  end

  describe "the admin page" do
    test "offers the form and lists the events", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/webhooks")

      assert html =~ "webhook-form"
      assert html =~ "report.created"
      assert html =~ "No webhooks yet"
    end

    test "adds one and shows the secret exactly once", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/webhooks")

      html =
        live
        |> form("#webhook-form", %{
          "url" => "https://example.com/hooks/abuuba",
          "events" => ["report.created"]
        })
        |> render_submit()

      assert html =~ "not shown again"
      assert [%Webhook{enabled: false} = webhook] = Webhooks.list()
      assert html =~ webhook.secret

      # And not on the next load: a secret that stays readable leaks with the
      # first screenshot of the page it is on.
      {:ok, _live, html} = live(conn, ~p"/admin/webhooks")
      refute html =~ webhook.secret
    end

    test "turns one on and off", %{conn: conn} do
      webhook = webhook_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/webhooks")
      live |> element("button[phx-click='enable_webhook']") |> render_click()
      assert Repo.reload!(webhook).enabled

      {:ok, live, _html} = live(conn, ~p"/admin/webhooks")
      live |> element("button[phx-click='disable_webhook']") |> render_click()
      refute Repo.reload!(webhook).enabled
    end

    test "removes one", %{conn: conn} do
      webhook = webhook_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/webhooks")
      html = live |> element("button[phx-click='delete_webhook']") |> render_click()

      assert html =~ "No webhooks yet"
      assert is_nil(Repo.reload(webhook))
    end

    test "shows the delivery log", %{conn: conn} do
      webhook = webhook_fixture()
      :ok = Webhooks.record(webhook, "report.created", status: 503, error: "server error")

      {:ok, _live, html} = live(conn, ~p"/admin/webhooks")

      # A webhook that has quietly stopped working looks exactly like a server
      # where nothing has happened.
      assert html =~ "503"
      assert html =~ "server error"
    end

    test "is refused to a moderator without that permission", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(log_in(conn, admin(["view_dashboard"])), ~p"/admin/webhooks")
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end

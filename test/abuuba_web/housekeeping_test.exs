defmodule AbuubaWeb.HousekeepingTest do
  use AbuubaWeb.ConnCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.LoginActivities
  alias Abuuba.Accounts.User
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Cleanup

  @password "a passphrase nobody guesses"

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      %{account_id: account.id, email: "alice@example.com", approved: true}
      |> Map.put(:confirmed_at, DateTime.utc_now())
      |> user_fixture()
      |> User.password_changeset(%{password: @password})
      |> Repo.update!()

    %{conn: log_in(conn, user), account: account, user: user}
  end

  defp aged(status, days) do
    then = DateTime.add(DateTime.utc_now(), -days, :day)

    status |> Ecto.Changeset.change(inserted_at: then) |> Repo.update!()
  end

  defp wants(user, attrs) do
    user |> User.cleanup_changeset(attrs) |> Repo.update!()
  end

  describe "deleting my own old posts" do
    test "is off until somebody turns it on", %{user: user, account: account} do
      aged(status_fixture(%{account_id: account.id, text: "old"}), 400)

      assert Cleanup.run(user) == 0
      assert Cleanup.due(user, :count) == 0
    end

    test "takes what is older and leaves what is not", %{user: user, account: account} do
      old = aged(status_fixture(%{account_id: account.id, text: "old"}), 400)
      recent = status_fixture(%{account_id: account.id, text: "recent"})

      user = wants(user, %{cleanup_after_days: 30})

      assert Cleanup.run(user) == 1
      assert Repo.reload!(old).deleted_at
      refute Repo.reload!(recent).deleted_at
    end

    test "keeps pinned posts unless told otherwise", %{user: user, account: account} do
      pinned = aged(status_fixture(%{account_id: account.id, text: "pinned"}), 400)
      {:ok, _pin} = Statuses.pin(account, pinned)

      user = wants(user, %{cleanup_after_days: 30, cleanup_keep_pinned: true})
      assert Cleanup.run(user) == 0
      refute Repo.reload!(pinned).deleted_at

      # And goes when somebody says it may.
      user = wants(user, %{cleanup_keep_pinned: false})
      assert Cleanup.run(user) == 1
      assert Repo.reload!(pinned).deleted_at
    end

    test "keeps posts people liked, above the threshold", %{user: user, account: account} do
      loved = aged(status_fixture(%{account_id: account.id, text: "loved"}), 400)
      ignored = aged(status_fixture(%{account_id: account.id, text: "ignored"}), 400)

      for _ <- 1..3, do: Statuses.favourite(account_fixture(), loved)

      user = wants(user, %{cleanup_after_days: 30, cleanup_min_favourites: 3})

      assert Cleanup.run(user) == 1
      refute Repo.reload!(loved).deleted_at
      assert Repo.reload!(ignored).deleted_at
    end

    test "counts what would go before anybody presses save", %{user: user, account: account} do
      for _ <- 1..3, do: aged(status_fixture(%{account_id: account.id, text: "old"}), 400)

      user = wants(user, %{cleanup_after_days: 30})

      # Being told "this will delete three posts" before the fact is the
      # difference between a setting and a surprise.
      assert Cleanup.due(user, :count) == 3
    end

    test "the worker runs it for everybody who asked", %{user: user, account: account} do
      aged(status_fixture(%{account_id: account.id, text: "old"}), 400)
      wants(user, %{cleanup_after_days: 30})

      assert :ok = perform_job(Abuuba.Statuses.CleanupWorker, %{})
      assert Cleanup.due(Repo.reload!(user), :count) == 0
    end
  end

  describe "the sign-in record" do
    test "notes a sign-in", %{user: user} do
      build_conn()
      |> post(~p"/login", %{"user" => %{"email" => user.email, "password" => @password}})
      |> redirected_to()

      assert [%{success: true, ip: ip}] = LoginActivities.recent(user)
      assert is_binary(ip)
    end

    test "notes a wrong password against the account it was aimed at", %{user: user} do
      build_conn()
      |> post(~p"/login", %{"user" => %{"email" => user.email, "password" => "not it"}})

      # The failures are the point: somebody else trying is the thing worth
      # spotting early, and nothing else on the server would say so.
      assert [%{success: false, failure_reason: "bad_password"}] = LoginActivities.recent(user)
    end

    test "writes nothing for an address that has no account" do
      build_conn()
      |> post(~p"/login", %{"user" => %{"email" => "nobody@example.com", "password" => "x"}})

      assert Repo.all(Abuuba.Accounts.LoginActivity) == []
    end

    test "is swept once it is old enough", %{user: user} do
      LoginActivities.record(user, success: true)

      Abuuba.Accounts.LoginActivity
      |> Repo.all()
      |> Enum.each(fn row ->
        row
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(DateTime.utc_now(), -LoginActivities.keep_days() - 1, :day)
        )
        |> Repo.update!()
      end)

      assert LoginActivities.sweep() == 1
      assert LoginActivities.recent(user) == []
    end
  end

  describe "the settings pages" do
    test "show recent sign-ins", %{conn: conn, user: user} do
      LoginActivities.record(user, success: false, ip: "203.0.113.9", reason: "bad_password")

      {:ok, _live, html} = live(conn, ~p"/settings/security")

      assert html =~ "Recent sign-ins"
      assert html =~ "203.0.113.9"
      assert html =~ "Refused"
    end

    test "list pinned posts and unpin one", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id, text: "at the top"})
      {:ok, _pin} = Statuses.pin(account, status)

      {:ok, live, html} = live(conn, ~p"/settings/posting")
      assert html =~ "at the top"

      html = live |> element("button[phx-value-status='#{status.id}']") |> render_click()

      assert html =~ "Nothing pinned"
      assert Statuses.pinned(account) == []
    end

    test "save the cleanup settings", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/settings/posting")

      live
      |> form("#cleanup-form", %{
        "cleanup" => %{"cleanup_after_days" => "90", "cleanup_keep_media" => "true"}
      })
      |> render_submit()

      reloaded = Repo.reload!(user)
      assert reloaded.cleanup_after_days == 90
      assert reloaded.cleanup_keep_media
    end

    test "turn it off again by clearing the age", %{conn: conn, user: user} do
      wants(user, %{cleanup_after_days: 90})

      {:ok, live, _html} = live(conn, ~p"/settings/posting")

      live
      |> form("#cleanup-form", %{"cleanup" => %{"cleanup_after_days" => ""}})
      |> render_submit()

      # An empty field means "no rule", not zero, and not a validation error
      # somebody cannot get past.
      assert is_nil(Repo.reload!(user).cleanup_after_days)
    end

    test "refuse an age that is obviously a typo", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/settings/posting")

      html =
        live
        |> form("#cleanup-form", %{"cleanup" => %{"cleanup_after_days" => "1"}})
        |> render_submit()

      assert html =~ "at least 7 days"
      assert is_nil(Repo.reload!(user).cleanup_after_days)
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end

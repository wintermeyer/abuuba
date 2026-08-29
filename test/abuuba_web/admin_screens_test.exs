defmodule AbuubaWeb.AdminScreensTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.Suggestions
  alias Abuuba.Admin
  alias Abuuba.EmailSubscriptions
  alias Abuuba.EmailSubscriptions.Subscription
  alias Abuuba.Instance.UpdateCheck
  alias Abuuba.Moderation.DomainLists
  alias Abuuba.Moderation.Domains
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings

  setup %{conn: conn} do
    on_exit(fn ->
      Settings.put("suppressed_suggestions", [])
      Settings.put("update_check", false)
      Settings.put("email_subscriptions", false)
    end)

    %{conn: log_in(conn, staff(["manage_federation", "manage_taxonomies", "manage_settings"]))}
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

  describe "the domain lists" do
    test "write out what has been decided", %{conn: conn} do
      {:ok, _block} =
        Domains.block(account_fixture(), %{
          "domain" => "noisy.example",
          "severity" => "silence",
          "public_comment" => "spam"
        })

      body = conn |> get(~p"/admin/domain-lists/blocks/download") |> response(200)

      assert body =~ "#domain"
      assert body =~ "noisy.example"
      assert body =~ "silence"
    end

    test "read a list in, adding what is new", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/domain-lists")

      live
      |> form("#domain-import-form", %{
        "kind" => "blocks",
        "csv" => "#domain,#severity\r\nspam.example,suspend\r\nnoisy.example,silence\r\n"
      })
      |> render_submit()

      assert %{severity: "suspend"} = Domains.block_for("spam.example")
      assert %{severity: "silence"} = Domains.block_for("noisy.example")
    end

    test "leave a domain already decided about exactly as it is" do
      moderator = account_fixture()

      {:ok, _block} =
        Domains.block(moderator, %{"domain" => "known.example", "severity" => "silence"})

      # One paste should not be able to undo every decision made here, silently
      # and unrecoverably.
      assert {:ok, %{created: 0, skipped: 1}} =
               Domains.import_csv(moderator, "known.example,suspend\r\n")

      assert %{severity: "silence"} = Domains.block_for("known.example")
    end

    test "skip a severity this server does not know" do
      moderator = account_fixture()

      # A file from somebody else must not delete accounts here because a
      # column said a word this server has never seen.
      #
      # Skipped rather than silenced. Two importers used to disagree about
      # this: the one this screen called turned an unknown severity into a
      # silence, and the one it calls now counts the row and leaves it. The
      # refusal is the safer half -- applying something weaker than a shared
      # list asked for, while reporting success, leaves an admin believing
      # their list is in force when it is not, and the skipped count is what
      # tells them to look.
      assert {:ok, %{created: 0, skipped: 1}} =
               Domains.import_csv(moderator, "odd.example,obliterate\r\n")

      assert Domains.block_for("odd.example") == nil
    end

    test "round-trip through the exporter" do
      moderator = account_fixture()
      {1, 0} = DomainLists.import_allows(moderator, "friend.example\r\n")

      assert DomainLists.export_allows() =~ "friend.example"
      assert {0, 1} = DomainLists.import_allows(moderator, DomainLists.export_allows())
    end

    test "are refused to somebody without the permission", %{conn: conn} do
      assert conn
             |> log_in(staff(["view_dashboard"]))
             |> get(~p"/admin/domain-lists/blocks/download")
             |> redirected_to() == "/"
    end
  end

  describe "follow suggestions" do
    setup do
      popular = account_fixture(%{username: "popular", discoverable: true})
      for _ <- 1..3, do: Relationships.follow(account_fixture(), popular)

      %{popular: popular}
    end

    test "list who is being put in front of newcomers", %{conn: conn, popular: popular} do
      {:ok, _live, html} = live(conn, ~p"/admin/suggestions")

      assert html =~ Account.acct(popular)
    end

    test "taking somebody out is not a block", %{conn: conn, popular: popular} do
      {:ok, live, _html} = live(conn, ~p"/admin/suggestions")
      live |> element("button[phx-value-account='#{popular.id}']") |> render_click()

      assert Suggestions.suppressed?(popular)

      # Their account carries on exactly as before and nobody is told.
      reloaded = Repo.reload!(popular)
      assert is_nil(reloaded.suspended_at)
      assert is_nil(reloaded.silenced_at)
    end

    test "a suppressed account stops being suggested", %{popular: popular} do
      newcomer = account_fixture()
      follower = account_fixture()
      Relationships.follow(newcomer, follower)
      Relationships.follow(follower, popular)

      assert popular.id in Enum.map(Suggestions.for_account(newcomer), & &1.id)

      :ok = Suggestions.suppress(popular, true)

      refute popular.id in Enum.map(Suggestions.for_account(newcomer), & &1.id)
    end

    test "and can be put back", %{popular: popular} do
      :ok = Suggestions.suppress(popular, true)
      :ok = Suggestions.suppress(popular, false)

      refute Suggestions.suppressed?(popular)
    end
  end

  describe "the update check" do
    test "is off unless the admin turns it on" do
      refute UpdateCheck.enabled?()
      assert is_nil(UpdateCheck.latest_version())
      refute UpdateCheck.behind?()
    end

    test "says what it sends and where, before anybody agrees", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/settings")

      # Asking a third party whether this server is up to date tells them this
      # server exists. That should be a decision, not a discovery.
      assert html =~ "Off unless you turn it on"
      assert html =~ "Nothing about the accounts here"
      assert html =~ UpdateCheck.endpoint()
    end

    test "knows what this server is running" do
      assert UpdateCheck.current_version() =~ ~r/^\d/
    end
  end

  describe "email subscriptions" do
    test "count only the confirmed ones", %{conn: conn} do
      account = account_fixture(%{username: "writer"})
      user = user_fixture(%{account_id: account.id, approved: true})

      Settings.put("email_subscriptions", true)

      user
      |> Ecto.Changeset.change(settings: %{"email_subscriptions" => true})
      |> Repo.update!()

      :ok = EmailSubscriptions.subscribe(account, "one@example.com")
      :ok = EmailSubscriptions.subscribe(account, "two@example.com")

      [%{confirmed_at: nil} = first, _second] =
        Repo.all(Subscription)

      {:ok, _confirmed} = EmailSubscriptions.confirm(first)

      # An unconfirmed address is a claim somebody typed into a form. Counting
      # it would tell an admin this server is sending mail it is not.
      assert [%{count: 1}] = Admin.subscription_counts()

      {:ok, _live, html} = live(conn, ~p"/admin/subscriptions")
      assert html =~ "writer"
    end

    test "say so when nobody has any", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/subscriptions")

      assert html =~ "Nobody here has any subscribers"
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end

defmodule AbuubaWeb.AdminRelaysTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Admin
  alias Abuuba.Federation.Relay
  alias Abuuba.Federation.Relays
  alias Abuuba.Repo
  alias Abuuba.Roles

  setup %{conn: conn} do
    %{conn: log_in(conn, admin(["manage_federation"]))}
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

  describe "the relays page" do
    test "explains what a relay is and offers the form", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/relays")

      assert html =~ "relay-form"
      assert html =~ "No relays yet"
    end

    test "adds one and leaves it off", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/relays")

      html =
        live
        |> form("#relay-form", %{"inbox_url" => "https://relay.example/inbox"})
        |> render_submit()

      assert html =~ "relay.example"
      # Adding and turning on are separate steps, so a mistyped address can be
      # corrected before anything is sent to it.
      assert [%Relay{state: :idle}] = Relays.list()
    end

    test "refuses an address that is not an https inbox", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/relays")

      html =
        live
        |> form("#relay-form", %{"inbox_url" => "http://relay.example/inbox"})
        |> render_submit()

      assert html =~ "not an https inbox address"
      assert Relays.list() == []
    end

    test "turns one on, which sends the subscription", %{conn: conn} do
      {:ok, relay} = Relays.add("https://relay.example/inbox")

      {:ok, live, _html} = live(conn, ~p"/admin/relays")
      html = live |> element("button[phx-click='enable_relay']") |> render_click()

      assert html =~ "Waiting for the relay to answer"

      reloaded = Repo.reload!(relay)
      assert reloaded.state == :pending
      assert reloaded.follow_activity_id
    end

    test "shows it as on once the relay has answered", %{conn: conn} do
      {:ok, relay} = Relays.add("https://relay.example/inbox")
      {:ok, relay} = Relays.enable(relay)
      {:ok, _accepted} = Relays.accept(relay.follow_activity_id, "https://relay.example/actor")

      {:ok, _live, html} = live(conn, ~p"/admin/relays")

      assert html =~ ">On<" or html =~ "On\n"
      assert Relays.inboxes() == ["https://relay.example/inbox"]
    end

    test "turns one off again", %{conn: conn} do
      {:ok, relay} = Relays.add("https://relay.example/inbox")
      {:ok, _relay} = Relays.enable(relay)

      {:ok, live, _html} = live(conn, ~p"/admin/relays")
      live |> element("button[phx-click='disable_relay']") |> render_click()

      assert Repo.reload!(relay).state == :idle
      assert Relays.inboxes() == []
    end

    test "removes one", %{conn: conn} do
      {:ok, relay} = Relays.add("https://relay.example/inbox")

      {:ok, live, _html} = live(conn, ~p"/admin/relays")
      html = live |> element("button[phx-click='remove_relay']") |> render_click()

      assert html =~ "No relays yet"
      assert is_nil(Repo.reload(relay))
    end

    test "shows why one is not working", %{conn: conn} do
      {:ok, _relay} = Relays.add("https://relay.example/inbox")
      :ok = Relays.record_failure("https://relay.example/inbox", {:status, 503})

      {:ok, _live, html} = live(conn, ~p"/admin/relays")

      # A relay failing quietly looks exactly like a relay nobody has posted to
      # yet, and what to do about it is different in each case.
      assert html =~ "Last error"
      assert html =~ "503"
    end

    test "clears the error once one works again", %{conn: conn} do
      {:ok, _relay} = Relays.add("https://relay.example/inbox")
      :ok = Relays.record_failure("https://relay.example/inbox", {:status, 503})
      :ok = Relays.record_success("https://relay.example/inbox")

      {:ok, _live, html} = live(conn, ~p"/admin/relays")

      refute html =~ "Last error"
      assert html =~ "last sent"
    end

    test "writes who did what to the audit log", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/relays")

      live
      |> form("#relay-form", %{"inbox_url" => "https://relay.example/inbox"})
      |> render_submit()

      {:ok, live, _html} = live(conn, ~p"/admin/relays")
      live |> element("button[phx-click='enable_relay']") |> render_click()

      {:ok, live, _html} = live(conn, ~p"/admin/relays")
      live |> element("button[phx-click='disable_relay']") |> render_click()

      {:ok, live, _html} = live(conn, ~p"/admin/relays")
      live |> element("button[phx-click='remove_relay']") |> render_click()

      # A relay is a standing decision to send every public post here to
      # somebody else's machine. A server with more than one moderator should
      # be able to find out which of them made it without asking around.
      actions = Enum.map(Admin.audit_log(%{}), & &1.action)

      assert "relay.add" in actions
      assert "relay.enable" in actions
      assert "relay.disable" in actions
      assert "relay.remove" in actions
    end

    test "names the relay in the log rather than its id", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/relays")

      live
      |> form("#relay-form", %{"inbox_url" => "https://relay.example/inbox"})
      |> render_submit()

      # "relay #4" tells whoever reads the log a year later nothing at all,
      # and the row outlives the relay.
      entry = Admin.audit_log(%{}) |> Enum.find(&(&1.action == "relay.add"))

      assert entry.target_label == "https://relay.example/inbox"
      assert entry.account_handle
    end

    test "is refused to somebody without the permission", %{conn: conn} do
      # In the admin area for another reason, and still not allowed here: which
      # sections somebody sees is asked per section rather than at the door.
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(log_in(conn, admin(["view_dashboard"])), ~p"/admin/relays")
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end

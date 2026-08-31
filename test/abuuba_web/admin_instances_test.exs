defmodule AbuubaWeb.AdminInstancesTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Admin
  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.Instances
  alias Abuuba.Moderation.Domains
  alias Abuuba.Roles

  setup %{conn: conn} do
    remote = account_fixture(%{username: "far", domain: "remote.example"})
    status_fixture(%{account_id: remote.id, text: "from over there"})
    account_fixture(%{username: "also", domain: "remote.example"})
    account_fixture(%{username: "one", domain: "quiet.example"})

    %{conn: log_in(conn, staff(["manage_federation", "manage_blocks", "view_audit_log"]))}
  end

  defp staff(permissions) do
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

  describe "the list" do
    test "counts the accounts and posts on each peer" do
      [busiest | _rest] = Instances.list()

      # Busiest first, because that is the order an admin cares about: the
      # servers most of their people are talking to.
      assert busiest.domain == "remote.example"
      assert busiest.accounts == 2
      assert busiest.posts == 1
    end

    test "says a healthy peer is delivering", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/instances")

      assert html =~ "remote.example"
      assert html =~ "Delivering"
    end

    test "narrows to what somebody searched for" do
      assert [%{domain: "quiet.example"}] = Instances.list(%{query: "quiet"})
    end
  end

  describe "delivery" do
    test "can be stopped and started again", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/instances")

      html =
        live
        |> element("button[phx-value-domain='remote.example'][phx-click='stop_delivery']")
        |> render_click()

      assert html =~ "stopped by a moderator"
      assert Availability.stopped?("remote.example")

      {:ok, live, _html} = live(conn, ~p"/admin/instances")

      live
      |> element("button[phx-click='restart_delivery'][phx-value-domain='remote.example']")
      |> render_click()

      refute Availability.stopped?("remote.example")
    end

    test "shows why the last one failed, and forgets it when asked", %{conn: conn} do
      :ok = Instances.record_error("remote.example", {:status, 502})

      {:ok, live, html} = live(conn, ~p"/admin/instances")

      # A peer that has quietly stopped accepting deliveries looks exactly like
      # a peer whose people have gone quiet.
      assert html =~ "Last error"
      assert html =~ "502"

      html =
        live
        |> element("button[phx-click='clear_delivery_errors'][phx-value-domain='remote.example']")
        |> render_click()

      refute page(html) =~ "502"
    end

    test "forgetting the failures clears the bad days too" do
      Availability.record_failure("remote.example")
      assert Availability.failure_day_count("remote.example") == 1

      :ok = Instances.clear_delivery_errors("remote.example")

      # Waiting for the count to age out would leave a server that is back
      # treated as unreliable for days after it stopped being so.
      assert Availability.failure_day_count("remote.example") == 0
    end
  end

  describe "a moderator's note" do
    test "is kept against the server", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/instances")

      # Sent as the event, since every row carries the same form and picking one
      # by selector is picking one by position.
      render_submit(live, "save_instance_note", %{
        "domain" => "remote.example",
        "note" => "They answered our report"
      })

      assert Instances.get("remote.example").note == "They answered our report"
    end

    test "can be written about a server that has never failed" do
      # The availability row exists only for servers in trouble, and a note is
      # usually written about one that is working perfectly well.
      :ok = Instances.put_note("quiet.example", "Small, friendly")

      assert Instances.get("quiet.example").note == "Small, friendly"
    end

    test "is cleared by saving an empty one" do
      :ok = Instances.put_note("quiet.example", "Something")
      :ok = Instances.put_note("quiet.example", "   ")

      assert is_nil(Instances.get("quiet.example").note)
    end
  end

  describe "blocking from the list" do
    test "silences rather than suspends", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/instances")

      html =
        live
        |> element("button[phx-click='block_instance'][phx-value-domain='remote.example']")
        |> render_click()

      # One click from a list, so the quieter of the two. Whoever wants a
      # suspension has the full form and a decision to make.
      assert html =~ "Blocked"
      assert %{severity: "silence"} = Domains.block_for("remote.example")
    end

    test "and a block on a parent domain is reported on the subdomain", %{conn: conn} do
      # The screen read `domain_blocks` itself and matched the column exactly,
      # so it offered to block a server that already was: `Domains.suspended?/1`
      # said suspended and this said nothing, from the same row.
      account_fixture(%{username: "sub", domain: "mail.bad.example"})
      moderator = account_fixture()
      {:ok, _} = Domains.block(moderator, %{"domain" => "bad.example", "severity" => "suspend"})

      assert Domains.suspended?("mail.bad.example")

      {:ok, _live, html} = live(conn, ~p"/admin/instances")

      assert html =~ "mail.bad.example"

      assert Map.has_key?(Domains.blocks_for(["mail.bad.example"]), "mail.bad.example"),
             "the screen asks this, and it answered about a different question"
    end

    test "and the narrower block is the one that applies", %{conn: _conn} do
      moderator = account_fixture()
      {:ok, _} = Domains.block(moderator, %{"domain" => "bad.example", "severity" => "silence"})

      {:ok, _} =
        Domains.block(moderator, %{"domain" => "mail.bad.example", "severity" => "suspend"})

      assert %{severity: "suspend"} =
               Domains.blocks_for(["mail.bad.example"])["mail.bad.example"]

      assert %{severity: "silence"} =
               Domains.blocks_for(["other.bad.example"])["other.bad.example"]
    end
  end

  describe "the audit log" do
    test "records who stopped delivering to whom", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/instances")

      live
      |> element("button[phx-click='stop_delivery'][phx-value-domain='remote.example']")
      |> render_click()

      entry = Admin.audit_log(%{}) |> Enum.find(&(&1.action == "instance.stop_delivery"))

      assert entry
      assert entry.account_handle
    end
  end

  test "is refused to a moderator without that permission", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(log_in(conn, staff(["view_dashboard"])), ~p"/admin/instances")
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end

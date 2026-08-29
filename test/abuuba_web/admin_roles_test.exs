defmodule AbuubaWeb.AdminRolesTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Admin
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Roles.Role

  setup %{conn: conn} do
    {:ok, role} =
      Roles.create(%{
        name: "Senior",
        position: 500,
        permissions: Roles.mask(["manage_roles", "manage_users", "manage_reports"])
      })

    user = staff(role)

    %{conn: log_in(conn, user), user: user, role: role}
  end

  defp staff(role) do
    user =
      user_fixture(%{
        account_id: account_fixture().id,
        approved: true,
        confirmed_at: DateTime.utc_now()
      })

    {:ok, user} = Roles.assign(user, role)

    user
  end

  describe "the roles page" do
    test "lists the roles and explains the rules", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/roles")

      assert html =~ "Senior"
      assert html =~ "nobody may edit a role at or above their own"
    end

    test "says what each permission means in words", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/roles")

      # "manage_taxonomies" is a word this project made up, and the person
      # ticking the box has to know what they are handing over.
      assert html =~ "Approve what trends"
      assert html =~ "Handle reports"
    end

    test "creates one below the maker's own position", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/roles")

      live
      |> form("#role-editor", %{
        "name" => "Helper",
        "position" => "10",
        "color" => "#7c3aed",
        "permissions" => %{"manage_reports" => "true"}
      })
      |> render_submit()

      assert %Role{position: 10, color: "#7c3aed"} = created = Repo.get_by(Role, name: "Helper")
      assert Roles.names(created.permissions) == ["manage_reports"]
    end

    test "refuses one at or above the maker's own position", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/roles")

      html =
        live
        |> form("#role-editor", %{"name" => "Rival", "position" => "500", "permissions" => %{}})
        |> render_submit()

      # A role at your own position is a role that can edit you.
      assert html =~ "at or above your own position"
      assert is_nil(Repo.get_by(Role, name: "Rival"))
    end

    test "refuses to grant a permission the maker does not hold", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/roles")

      # Sent as the raw event rather than through the form: the box is disabled
      # in the markup, and a disabled box is not a check. Somebody can always
      # send the event anyway.
      render_submit(live, "save_role_definition", %{
        "name" => "Sneaky",
        "position" => "10",
        "permissions" => %{"administrator" => "true", "manage_reports" => "true"}
      })

      created = Repo.get_by(Role, name: "Sneaky")

      assert created
      assert Roles.names(created.permissions) == ["manage_reports"]
      refute "administrator" in Roles.names(created.permissions)
    end

    test "leaves a permission the editor cannot see exactly as it was", %{conn: conn} do
      {:ok, below} =
        Roles.create(%{
          name: "Odd",
          position: 10,
          permissions: Roles.mask(["manage_reports", "manage_custom_emojis"])
        })

      {:ok, live, _html} = live(conn, ~p"/admin/roles?edit=#{below.id}")

      live
      |> form("#role-editor", %{
        "role_id" => to_string(below.id),
        "name" => "Odd",
        "position" => "10",
        "permissions" => %{"manage_reports" => "true"}
      })
      |> render_submit()

      # Editing a role should not quietly strip a permission the editor could
      # not tick because they do not hold it themselves.
      assert "manage_custom_emojis" in Roles.names(Repo.reload!(below).permissions)
    end

    test "edits one that is below", %{conn: conn} do
      {:ok, below} = Roles.create(%{name: "Helper", position: 10, permissions: 0})

      {:ok, live, _html} = live(conn, ~p"/admin/roles?edit=#{below.id}")

      live
      |> form("#role-editor", %{
        "role_id" => to_string(below.id),
        "name" => "Helper II",
        "position" => "20",
        "permissions" => %{"manage_reports" => "true"}
      })
      |> render_submit()

      reloaded = Repo.reload!(below)
      assert reloaded.name == "Helper II"
      assert reloaded.position == 20
    end

    test "refuses to edit one upwards past the editor", %{conn: conn} do
      {:ok, below} = Roles.create(%{name: "Helper", position: 10, permissions: 0})

      {:ok, live, _html} = live(conn, ~p"/admin/roles?edit=#{below.id}")

      html =
        live
        |> form("#role-editor", %{
          "role_id" => to_string(below.id),
          "name" => "Helper",
          "position" => "900",
          "permissions" => %{}
        })
        |> render_submit()

      # Editing a role you may touch into a position you may not is the same
      # escalation as making one there.
      assert html =~ "at or above your own position"
      assert Repo.reload!(below).position == 10
    end

    test "removes one that is below", %{conn: conn} do
      {:ok, below} = Roles.create(%{name: "Helper", position: 10, permissions: 0})

      {:ok, live, _html} = live(conn, ~p"/admin/roles")
      live |> element("button[phx-value-role='#{below.id}']") |> render_click()

      assert is_nil(Repo.reload(below))
    end

    test "offers no buttons for a role above the reader", %{conn: conn} do
      {:ok, _above} = Roles.create(%{name: "Boss", position: 900, permissions: 0})

      {:ok, _live, html} = live(conn, ~p"/admin/roles")

      assert html =~ "Above yours"
    end

    test "writes every change to the audit log", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/roles")

      live
      |> form("#role-editor", %{"name" => "Helper", "position" => "10", "permissions" => %{}})
      |> render_submit()

      entry = Admin.audit_log(%{}) |> Enum.find(&(&1.action == "role.create"))

      assert entry.target_label == "Helper"
      assert entry.account_handle
    end

    test "is refused to a moderator without that permission", %{conn: conn} do
      {:ok, plain} =
        Roles.create(%{name: "Reader", position: 5, permissions: Roles.mask(["view_dashboard"])})

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(log_in(conn, staff(plain)), ~p"/admin/roles")
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end
end

defmodule AbuubaWeb.FirstUserAdminAreaTest do
  @moduledoc """
  The point of making the first account an admin is that it can open the admin
  area, so that is what this asserts rather than the role it was given.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Abuuba.Accounts.Auth
  alias Abuuba.Settings

  setup do
    Settings.put_registration_mode(:open)
    on_exit(fn -> Application.delete_env(:abuuba, :first_user_is_admin) end)

    :ok
  end

  defp register_and_sign_in(conn, username) do
    {:ok, %{user: user}} =
      Auth.register(
        %{
          "username" => username,
          "email" => "#{username}@example.com",
          "password" => "correct horse battery"
        },
        rules_required: false
      )

    # Confirmed and approved by hand: what is being tested is what the role
    # opens, not the sign-up flow that comes before it.
    {:ok, user} =
      user
      |> Ecto.Changeset.change(approved: true, confirmed_at: DateTime.utc_now())
      |> Abuuba.Repo.update()

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  test "the first account on a development server can open it", %{conn: conn} do
    Application.put_env(:abuuba, :first_user_is_admin, true)

    conn = register_and_sign_in(conn, "founder")

    assert {:ok, _live, _html} = live(conn, ~p"/admin")
  end

  test "and the second cannot", %{conn: conn} do
    Application.put_env(:abuuba, :first_user_is_admin, true)

    register_and_sign_in(conn, "founder")
    conn = register_and_sign_in(conn, "latecomer")

    assert {:error, _redirect} = live(conn, ~p"/admin")
  end

  test "nor the first one anywhere the setting is off", %{conn: conn} do
    Application.put_env(:abuuba, :first_user_is_admin, false)

    conn = register_and_sign_in(conn, "founder")

    assert {:error, _redirect} = live(conn, ~p"/admin")
  end
end

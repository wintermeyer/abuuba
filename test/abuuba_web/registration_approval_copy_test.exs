defmodule AbuubaWeb.RegistrationApprovalCopyTest do
  @moduledoc """
  What the "check your email" screen says about a moderator.

  The screen used to ask the server how it treats sign-ups in general. Two
  people it is wrong for are let straight in on a server that moderates:
  somebody arriving on an invitation, and the founder of a development server.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Invites.Invite
  alias Abuuba.Repo
  alias Abuuba.Settings

  @moderator_line "a moderator reads your registration"

  setup do
    Settings.put_registration_mode(:approved)
    on_exit(fn -> Application.delete_env(:abuuba, :first_user_is_admin) end)

    :ok
  end

  defp submit(conn, params, path \\ "/register") do
    {:ok, view, _html} = live(conn, path)

    view |> form("form", user: params) |> render_submit()
  end

  defp details(username, extra \\ %{}) do
    Map.merge(
      %{
        username: username,
        email: "#{username}@example.com",
        password: "correct horse battery",
        invite_reason: "I would like to join"
      },
      extra
    )
  end

  test "somebody in the queue is told a moderator will read it", %{conn: conn} do
    html = submit(conn, details("waiting"))

    assert html =~ "Check your email"
    assert html =~ @moderator_line
  end

  test "somebody arriving on an invitation is not", %{conn: conn} do
    # Through the URL, which is where an invite actually arrives: the form
    # carries it as a hidden field filled in from there.
    # No reason field on an invited sign-up: somebody here has already vouched,
    # so the form does not ask the applicant to explain themselves.
    params = Map.delete(details("invited"), :invite_reason)

    html = submit(conn, params, "/register?invite=#{invite_code()}")

    assert html =~ "Check your email"
    refute html =~ @moderator_line
  end

  test "and neither is the founder of a development server", %{conn: conn} do
    Application.put_env(:abuuba, :first_user_is_admin, true)

    html = submit(conn, details("founder"))

    assert html =~ "Check your email"
    refute html =~ @moderator_line
  end

  # Written straight in rather than through `Invites.create/2`, which asks
  # whether the account may invite. Who may issue one is a different subject
  # from what the screen says to somebody holding one.
  defp invite_code do
    # Upper case: `Invites.get_by_code/1` upcases what it is given, so a
    # lower-case code in the row is a code nothing can ever find.
    code = "INVITE#{System.unique_integer([:positive])}"

    Repo.insert!(%Invite{account_id: account_fixture().id, code: code})

    code
  end
end

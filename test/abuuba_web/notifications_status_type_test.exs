defmodule AbuubaWeb.NotificationsStatusTypeTest do
  @moduledoc """
  The bell's notifications where somebody reads them: on the notifications
  screen, and through the API a client filters by type.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.OAuth
  alias Abuuba.Relationships

  setup do
    reader = account_fixture()

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    author = account_fixture(%{username: "watched#{System.unique_integer([:positive])}"})
    {:ok, _follow} = Relationships.follow(reader, author, %{notify: true})

    status = status_fixture(%{account_id: author.id, text: "something worth hearing about"})

    %{reader: reader, user: user, author: author, status: status}
  end

  defp sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  test "the screen says who posted", %{conn: conn, user: user, author: author} do
    {:ok, _live, html} = live(sign_in(conn, user), ~p"/notifications")

    assert html =~ "posted"
    assert html =~ author.username
  end

  test "and offers it as something to filter by", %{conn: conn, user: user} do
    {:ok, _live, html} = live(sign_in(conn, user), ~p"/notifications")

    assert html =~ "Posts from people you watch"
  end

  test "a client can ask for only these", %{user: user, status: status} do
    {:ok, application, _secret} =
      OAuth.create_application(%{name: "Ivory", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

    body =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
      |> get(~p"/api/v1/notifications?types[]=status")
      |> json_response(200)

    assert [%{"type" => "status"} = notification] = body
    assert notification["status"]["id"] == to_string(status.id)
  end

  test "and excluding them leaves nothing", %{user: user} do
    # The positive control's mirror: if the type filter were ignored, the
    # request above would pass for the wrong reason.
    {:ok, application, _secret} =
      OAuth.create_application(%{name: "Ivory", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

    body =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
      |> get(~p"/api/v1/notifications?exclude_types[]=status")
      |> json_response(200)

    assert body == []
  end
end

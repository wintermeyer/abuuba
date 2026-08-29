defmodule AbuubaWeb.API.SearchResolveHandleTest do
  @moduledoc """
  Finding somebody on another server by their handle.

  The most ordinary thing anybody does on the fediverse: paste
  `@someone@their.server` into search. It only works if the server will go and
  ask that server who they are, which is what `resolve=true` means.
  """

  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.OAuth

  setup do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "search", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

    %{conn: put_req_header(build_conn(), "authorization", "Bearer " <> raw)}
  end

  defp search(conn, query, params \\ %{}) do
    conn
    |> get(~p"/api/v2/search", Map.merge(%{"q" => query, "resolve" => "true"}, params))
    |> json_response(200)
  end

  describe "a handle" do
    test "is looked up on the server it names", %{conn: conn} do
      # Already here, so nothing is fetched: what is being tested is that a
      # handle is understood as a handle rather than pushed through the URL
      # path, which answered with nothing at all.
      remote =
        remote_account_fixture(%{
          username: "alice",
          domain: "remote.example",
          uri: "https://remote.example/users/alice"
        })

      assert %{"accounts" => [found]} = search(conn, "alice@remote.example")
      assert found["id"] == to_string(remote.id)
    end

    test "with a leading @, which is how anybody writes one", %{conn: conn} do
      remote =
        remote_account_fixture(%{
          username: "alice",
          domain: "remote.example",
          uri: "https://remote.example/users/alice"
        })

      assert %{"accounts" => [found]} = search(conn, "@alice@remote.example")
      assert found["id"] == to_string(remote.id)
    end

    test "and a local one, written the same way", %{conn: conn} do
      local = account_fixture(%{username: "bob"})

      assert %{"accounts" => [found]} = search(conn, "@bob")
      assert found["id"] == to_string(local.id)
    end
  end

  describe "what it does not change" do
    test "a URL is still resolved as a URL", %{conn: conn} do
      remote =
        remote_account_fixture(%{
          username: "carol",
          domain: "remote.example",
          uri: "https://remote.example/users/carol"
        })

      assert %{"accounts" => [found]} = search(conn, "https://remote.example/users/carol")
      assert found["id"] == to_string(remote.id)
    end

    test "and a handle nobody has is simply not found", %{conn: conn} do
      # The positive control's mirror: if this answered with somebody, the
      # assertions above would prove nothing about which account came back.
      assert %{"accounts" => []} = search(conn, "nobody@remote.example")
    end
  end
end

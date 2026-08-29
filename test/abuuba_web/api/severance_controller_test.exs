defmodule AbuubaWeb.API.SeveranceControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Moderation.Domains
  alias Abuuba.OAuth
  alias Abuuba.Relationships

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      anon: build_conn(),
      account: account,
      moderator: account_fixture()
    }
  end

  test "says what a decision here cost this account", %{
    conn: conn,
    account: account,
    moderator: mod
  } do
    them = remote_account_fixture(%{domain: "bad.example"})
    other = remote_account_fixture(%{domain: "bad.example", username: "second"})
    {:ok, _} = Relationships.follow(account, them)
    {:ok, _} = Relationships.follow(account, other)

    {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

    assert [entry] = json_response(get(conn, "/api/v1/severed_relationships"), 200)

    assert entry["type"] == "domain_block"
    assert entry["target_name"] == "bad.example"
    assert entry["relationships_count"] == 2
    assert is_binary(entry["id"])
  end

  test "says nothing to somebody who lost nothing", %{conn: conn, moderator: mod} do
    {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

    assert json_response(get(conn, "/api/v1/severed_relationships"), 200) == []
  end

  test "is not a public list", %{anon: anon, moderator: mod} do
    # It names who somebody followed, which is theirs.
    {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

    assert json_response(get(anon, "/api/v1/severed_relationships"), 422)["error"]
  end
end

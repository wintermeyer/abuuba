defmodule AbuubaWeb.API.ReportControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.OAuth

  setup %{conn: conn} do
    account = account_fixture()

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      account: account,
      target: account_fixture()
    }
  end

  test "records a report and hands it back", %{conn: conn, target: target} do
    body =
      conn
      |> post("/api/v1/reports", %{
        "account_id" => to_string(target.id),
        "category" => "spam",
        "comment" => "nothing but links"
      })
      |> json_response(200)

    assert body["category"] == "spam"
    assert body["comment"] == "nothing but links"
    refute body["action_taken"]
    refute body["forwarded"]
  end

  test "a category nobody defined becomes other rather than a refusal", %{
    conn: conn,
    target: target
  } do
    # The complaint is what matters. Losing it over an unknown category would
    # be losing the thing the endpoint exists for.
    body =
      conn
      |> post("/api/v1/reports", %{"account_id" => to_string(target.id), "category" => "vibes"})
      |> json_response(200)

    assert body["category"] == "other"
  end

  test "keeps only evidence the reported account wrote", %{conn: conn, target: target} do
    theirs = Abuuba.StatusesFixtures.status_fixture(%{account_id: target.id})
    somebody_else = Abuuba.StatusesFixtures.status_fixture(%{account_id: account_fixture().id})

    body =
      conn
      |> post("/api/v1/reports", %{
        "account_id" => to_string(target.id),
        "status_ids" => [to_string(theirs.id), to_string(somebody_else.id)]
      })
      |> json_response(200)

    assert body["status_ids"] == [to_string(theirs.id)]
  end

  test "an account nobody has is a plain miss", %{conn: conn} do
    assert json_response(post(conn, "/api/v1/reports", %{"account_id" => "999999999999"}), 404)
  end

  test "reporting yourself is refused", %{conn: conn, account: account} do
    assert json_response(
             post(conn, "/api/v1/reports", %{"account_id" => to_string(account.id)}),
             422
           )
  end

  test "somebody with no token cannot file one", %{target: target} do
    conn = post(build_conn(), "/api/v1/reports", %{"account_id" => to_string(target.id)})

    assert json_response(conn, 422)
  end
end

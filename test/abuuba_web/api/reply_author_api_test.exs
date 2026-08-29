defmodule AbuubaWeb.API.ReplyAuthorAPITest do
  @moduledoc """
  What a client gets back when it posts a reply.

  `in_reply_to_account_id` is how a client draws "in reply to @somebody", so a
  null there is a reply that renders as if it answered nobody.
  """

  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.OAuth

  setup do
    author = account_fixture()

    user =
      user_fixture(%{account_id: author.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "Ivory", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    %{author: author, token: raw}
  end

  defp post_status(token, params) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> post(~p"/api/v1/statuses", params)
    |> json_response(200)
  end

  test "a reply names the account it answers", %{token: token} do
    parent = status_fixture(%{text: "a question"})

    body =
      post_status(token, %{"status" => "an answer", "in_reply_to_id" => to_string(parent.id)})

    assert body["in_reply_to_id"] == to_string(parent.id)
    assert body["in_reply_to_account_id"] == to_string(parent.account_id)
  end

  test "and a post that answers nothing names nobody", %{token: token} do
    body = post_status(token, %{"status" => "on its own"})

    assert body["in_reply_to_id"] == nil
    assert body["in_reply_to_account_id"] == nil
  end
end

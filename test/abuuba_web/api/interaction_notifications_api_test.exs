defmodule AbuubaWeb.API.InteractionNotificationsAPITest do
  @moduledoc """
  What a client is handed when somebody favourites, boosts or follows.

  There is a test beside this one asserting the rows exist. This one is about
  the layer above, and exists because of how the original bug survived: every
  notification test built its rows by calling `notify/4` directly, so the whole
  suite passed while nothing in the server ever called it for five of the
  types. A test that produces its own rows cannot notice that nothing else
  does, and it cannot notice a renderer with no clause for a type either --
  which would be a 500 rather than an empty list.

  So the interactions here are made the way a person makes them, and read back
  through both endpoints a client actually uses.
  """
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  setup %{conn: conn} do
    author = account_fixture()

    user =
      user_fixture(%{account_id: author.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])

    %{conn: put_req_header(conn, "authorization", "Bearer " <> raw), author: author}
  end

  describe "the notifications a client reads" do
    setup %{author: author} do
      reader = account_fixture()
      status = status_fixture(%{account_id: author.id, text: "hello"})

      {:ok, _} = Statuses.favourite(reader, status)
      {:ok, _} = Statuses.boost(reader, status)
      {:ok, _} = Relationships.follow(reader, author)
      {:ok, _} = Relationships.request_follow(account_fixture(), author)

      %{status: status, reader: reader}
    end

    test "carry every kind of interaction", %{conn: conn} do
      body = conn |> get(~p"/api/v1/notifications") |> json_response(200)

      assert body |> Enum.map(& &1["type"]) |> Enum.sort() ==
               ["favourite", "follow", "follow_request", "reblog"]

      for entry <- body do
        assert entry["account"]["id"], "#{entry["type"]} came back without a sender"
        assert entry["group_key"], "#{entry["type"]} came back without a group key"
        assert entry["created_at"]
      end
    end

    test "name the post where there is one, and the boost for a boost", %{
      conn: conn,
      status: status
    } do
      body = conn |> get(~p"/api/v1/notifications") |> json_response(200)
      by_type = Map.new(body, &{&1["type"], &1})

      assert by_type["favourite"]["status"]["id"] == to_string(status.id)
      # A boost names the boost, whose `reblog` carries what was boosted --
      # the shape upstream sends, and what lets unboosting take it back.
      assert by_type["reblog"]["status"]["reblog"]["id"] == to_string(status.id)
      refute by_type["follow"]["status"]
    end

    test "and group the same way through v2", %{conn: conn} do
      body = conn |> get(~p"/api/v2/notifications") |> json_response(200)

      assert length(body["notification_groups"]) == 4

      for group <- body["notification_groups"] do
        assert group["group_key"]
        assert group["notifications_count"] >= 1
        assert group["sample_account_ids"] != []
      end
    end
  end
end

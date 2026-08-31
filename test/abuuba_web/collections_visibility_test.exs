defmodule AbuubaWeb.CollectionsVisibilityTest do
  @moduledoc """
  Who may see who follows an account, on every surface that answers it.

  The question was written four times in four shapes: a function head in the
  REST controller, a `cond` with two private helpers on the profile page, a
  single pattern match in the ActivityPub controller, and a fourth spelling
  guarding the featured strip. Each of them was right about the rule it
  remembered and silent about the rest, and two of the comments each said the
  *other* surfaces already honoured the setting.

  Written per surface rather than per rule, for the reason
  `AbuubaWeb.ReaderRulesTest` gives: the bug is not that a rule was wrong, it
  is that a surface never asked.
  """
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.OAuth
  alias Abuuba.Relationships

  setup %{conn: conn} do
    subject = account_fixture(%{username: "alice"})
    follower = account_fixture(%{username: "carol"})
    {:ok, _} = Relationships.follow(follower, subject)

    reader = account_fixture(%{username: "reader"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    signed_in =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))

    # A session cookie is not a token: on an API route it leaves the viewer
    # `nil`, which reads as "a stranger" and would pass every assertion below
    # for the wrong reason.
    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read"])
    with_token = put_req_header(build_conn(), "authorization", "Bearer " <> raw)

    %{
      conn: conn,
      signed_in: signed_in,
      with_token: with_token,
      subject: subject,
      reader: reader
    }
  end

  # The three doors onto one list. ActivityPub is here as a peer rather than a
  # reader, which is why it takes no viewer at all.
  defp listed_for_reader?(signed_in) do
    signed_in |> get(~p"/@alice/followers") |> html_response(200) =~ "carol"
  end

  defp listed_for_api?(with_token) do
    subject = Accounts.lookup("alice")

    with_token
    |> get(~p"/api/v1/accounts/#{subject.id}/followers")
    |> json_response(200)
    |> Enum.any?(&(&1["username"] == "carol"))
  end

  defp listed_for_peer?(conn) do
    conn |> get(~p"/users/alice/followers") |> json_response(200) |> Map.get("totalItems") > 0
  end

  describe "an account that has asked for nothing in particular" do
    test "shows the list on all three", %{
      conn: conn,
      signed_in: signed_in,
      with_token: with_token
    } do
      # The control. Every assertion below is that something is absent, which
      # a server showing nobody anything would satisfy just as well.
      assert listed_for_reader?(signed_in)
      assert listed_for_api?(with_token)
      assert listed_for_peer?(conn)
    end
  end

  describe "an account that hid its collections" do
    setup %{subject: subject} do
      {:ok, _} = Accounts.update_profile(subject, %{"hide_collections" => true})
      :ok
    end

    test "shows it on none of them", %{
      conn: conn,
      signed_in: signed_in,
      with_token: with_token
    } do
      refute listed_for_reader?(signed_in)
      refute listed_for_api?(with_token)
      refute listed_for_peer?(conn)
    end

    test "and still shows the owner their own", %{subject: subject, conn: conn} do
      owner =
        user_fixture(%{
          account_id: subject.id,
          approved: true,
          confirmed_at: DateTime.utc_now()
        })

      as_owner =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, Auth.create_session_token(owner))

      assert listed_for_reader?(as_owner)
    end
  end

  describe "a reader the account has blocked" do
    setup %{subject: subject, reader: reader} do
      {:ok, _} = Relationships.block(subject, reader)
      :ok
    end

    test "is refused by the two that know who is asking", %{
      signed_in: signed_in,
      with_token: with_token
    } do
      refute listed_for_reader?(signed_in)
      refute listed_for_api?(with_token)
    end

    test "and the federation side is unchanged, because it has no reader", %{conn: conn} do
      # A peer fetching a document is nobody in particular. Answering the
      # setting and stopping there is what this endpoint has always done, and
      # a block is between two accounts rather than between two servers.
      assert listed_for_peer?(conn)
    end
  end
end

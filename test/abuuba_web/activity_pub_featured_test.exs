defmodule AbuubaWeb.ActivityPubFeaturedTest do
  @moduledoc """
  What an account has put on its own profile, as other servers read it.

  abuuba has always accepted an `Add` or a `Remove` on somebody else's featured
  collection and published none of its own, so a pinned post here showed up on
  the profile page and nowhere on the network. These are the two endpoints a
  peer reads to find out, and the two properties on the actor document that
  tell it where to look.
  """

  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Serializer
  alias Abuuba.Statuses

  defp document(conn), do: json_response(conn, 200)

  describe "the featured collection" do
    setup do
      account = account_fixture(%{username: "alice"})
      %{account: account, collection: "#{Actor.id(account)}/collections/featured"}
    end

    test "is empty rather than missing when nothing is pinned", %{
      conn: conn,
      collection: collection
    } do
      body = conn |> get(~p"/users/alice/collections/featured") |> document()

      assert body["id"] == collection
      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 0
      assert body["orderedItems"] == []
    end

    test "carries the pinned posts in full, newest pin first", %{
      conn: conn,
      account: account,
      collection: collection
    } do
      older = status_fixture(%{account_id: account.id, text: "older"})
      newer = status_fixture(%{account_id: account.id, text: "newer"})
      {:ok, _pin} = Statuses.pin(account, older)
      {:ok, _pin} = Statuses.pin(account, newer)

      body = conn |> get(~p"/users/alice/collections/featured") |> document()

      assert body["id"] == collection
      assert body["totalItems"] == 2

      # In full rather than by reference: a peer rendering a profile would
      # otherwise have to fetch every pin before it could show anything.
      assert [first, second] = body["orderedItems"]
      assert first["type"] == "Note"
      assert first["id"] == Serializer.status_uri(newer, account)
      assert second["id"] == Serializer.status_uri(older, account)
    end

    test "is served as activity+json", %{conn: conn} do
      conn = get(conn, ~p"/users/alice/collections/featured")

      assert conn |> get_resp_header("content-type") |> hd() =~ "application/activity+json"
    end

    test "drops a pin whose post has gone", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id})
      {:ok, _pin} = Statuses.pin(account, status)
      {:ok, _deleted} = Statuses.delete_status(status)

      body = conn |> get(~p"/users/alice/collections/featured") |> document()

      assert body["totalItems"] == 0
    end

    test "is served on the numeric scheme too", %{conn: conn, account: account} do
      status = status_fixture(%{account_id: account.id})
      {:ok, _pin} = Statuses.pin(account, status)

      body = conn |> get(~p"/ap/users/#{account.id}/collections/featured") |> document()

      assert body["totalItems"] == 1
    end

    test "is not served for somebody who is not here", %{conn: conn} do
      assert conn |> get(~p"/users/nobody/collections/featured") |> json_response(404)
    end

    test "is not served for an account from another server", %{conn: conn} do
      remote_account_fixture(%{username: "bob", domain: "peer.example"})

      assert conn |> get(~p"/users/bob/collections/featured") |> json_response(404)
    end
  end

  describe "the featured tags collection" do
    setup do
      account = account_fixture(%{username: "alice"})
      %{account: account}
    end

    test "names each tag the way a peer renders it", %{conn: conn, account: account} do
      tag = tag_fixture("elixir")
      :ok = Statuses.feature_tag(account, tag)

      body = conn |> get(~p"/users/alice/collections/tags") |> document()

      assert body["id"] == "#{Actor.id(account)}/collections/tags"
      assert body["type"] == "Collection"
      assert body["totalItems"] == 1

      assert [%{"type" => "Hashtag", "name" => "#elixir", "href" => href}] = body["items"]
      assert href =~ "/tags/elixir"
    end

    test "declares the Hashtag term it uses", %{conn: conn, account: account} do
      :ok = Statuses.feature_tag(account, tag_fixture("elixir"))

      body = conn |> get(~p"/users/alice/collections/tags") |> document()

      # Without the term a strict peer reads `Hashtag` as an undefined type and
      # drops every item in the collection.
      assert body["@context"]
    end

    test "is empty rather than missing when nothing is featured", %{conn: conn} do
      body = conn |> get(~p"/users/alice/collections/tags") |> document()

      assert body["totalItems"] == 0
      assert body["items"] == []
    end
  end

  describe "an unknown collection" do
    test "is a 404 rather than an empty one", %{conn: conn} do
      # An empty answer would tell a peer that the collection exists and that
      # this account has nothing in it, which is not true of a name we do not
      # serve at all.
      account_fixture(%{username: "alice"})

      assert conn |> get(~p"/users/alice/collections/nonsense") |> json_response(404)
    end
  end

  describe "the actor document" do
    test "says where both collections live", %{conn: conn} do
      account = account_fixture(%{username: "alice"})

      body = conn |> get(~p"/users/alice") |> document()

      assert body["featured"] == "#{Actor.id(account)}/collections/featured"
      assert body["featuredTags"] == "#{Actor.id(account)}/collections/tags"
    end
  end
end

defmodule AbuubaWeb.PastedAddressTest do
  @moduledoc """
  What a machine gets for every shape of address a person can paste.

  The addresses abuuba shows people -- `/@alice`, `/@alice/123` -- are the ones
  that get copied into other servers' search boxes. The server on the other
  end fetches them asking for ActivityPub and falls back to reading the HTML
  for a `rel=alternate` link. abuuba answered with a page carrying no such link,
  so pasting an abuuba address anywhere else found nothing: the mirror image of
  `HumanRedirect`, which already sends a browser from a machine address to the
  page.

  The second half is canonical ids. An account has one actor id -- which of
  the two URI shapes it is depends on `id_scheme` -- and fetching the *other*
  shape served a document whose id was not the URL it came from. Strict peers
  check exactly that. A wrong shape now answers 301 to the right one, so every
  chain ends on a document whose id is the address it was fetched from.
  """
  use AbuubaWeb.ConnCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Serializer

  # What the reference implementation's fetcher actually sends: AP first,
  # HTML as a last resort.
  @machine_accept ~s(application/activity+json, application/ld+json; profile="https://www.w3.org/ns/activitystreams", text/html;q=0.1)
  @browser_accept "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

  defp machine(conn), do: put_req_header(conn, "accept", @machine_accept)
  defp browser(conn), do: put_req_header(conn, "accept", @browser_accept)

  for scheme <- [:username, :numeric] do
    describe "a pasted profile address, #{scheme} scheme" do
      setup do
        account = account_fixture(%{id_scheme: unquote(scheme)})
        status = status_fixture(%{account_id: account.id, text: "paste me"})

        %{account: account, status: status}
      end

      test "leads a machine to the actor document", %{conn: conn, account: account} do
        conn = conn |> machine() |> get("/@#{account.username}")

        assert conn.status == 301
        [location] = get_resp_header(conn, "location")

        # Follow the chain to its end: wherever it lands must be the document
        # whose id is that address.
        {final, document} = follow_to_document(location)

        assert document["id"] == Actor.id(account)
        assert final == URI.parse(Actor.id(account)).path
      end

      test "and a pasted post address to the post", %{
        conn: conn,
        account: account,
        status: status
      } do
        conn = conn |> machine() |> get("/@#{account.username}/#{status.id}")

        assert conn.status == 301
        [location] = get_resp_header(conn, "location")

        {final, document} = follow_to_document(location)

        assert document["id"] == Serializer.status_uri(status, account)
        assert final == URI.parse(Serializer.status_uri(status, account)).path
        assert document["content"] =~ "paste me"
      end

      test "while a browser still gets the page", %{conn: conn, account: account} do
        # The control: the redirect must not swallow people.
        html = conn |> browser() |> get("/@#{account.username}") |> html_response(200)

        assert html =~ account.username
      end

      test "whose HTML names the actor as its alternate", %{conn: conn, account: account} do
        # The fallback for a fetcher that got the page some other way.
        html = conn |> browser() |> get("/@#{account.username}") |> html_response(200)

        assert html =~ ~s(rel="alternate")
        assert html =~ ~s(type="application/activity+json")
        assert html =~ Actor.id(account)
      end

      test "and the post page names the post", %{conn: conn, account: account, status: status} do
        html =
          conn |> browser() |> get("/@#{account.username}/#{status.id}") |> html_response(200)

        assert html =~ ~s(type="application/activity+json")
        assert html =~ Serializer.status_uri(status, account)
      end

      test "the wrong actor shape answers with the right one", %{account: account} do
        # Both shapes must keep working forever; working means arriving at the
        # canonical document, not being handed a copy under the wrong name.
        wrong =
          case account.id_scheme do
            :numeric -> "/users/#{account.username}"
            :username -> "/ap/users/#{account.id}"
          end

        # The strict-peer property is that the chain *ends at* the id, not
        # merely that the document carries it: a document served under the
        # wrong URL with the right id inside is exactly what they refuse.
        {final, document} = follow_to_document(wrong)

        assert document["id"] == Actor.id(account)
        assert final == URI.parse(Actor.id(account)).path
      end

      test "and the follower pages are left alone", %{conn: conn, account: account} do
        # Narrowness control: only the two pasted shapes redirect. A machine
        # asking for the follower page gets the page, as before.
        status = conn |> machine() |> get("/@#{account.username}/followers") |> Map.get(:status)

        assert status == 200
      end
    end
  end

  defp follow_to_document(path, hops \\ 3)

  defp follow_to_document(_path, 0), do: flunk("the redirect chain did not end")

  defp follow_to_document(path, hops) do
    conn = build_conn() |> machine() |> get(URI.parse(path).path)

    case conn.status do
      301 ->
        [location] = get_resp_header(conn, "location")
        follow_to_document(location, hops - 1)

      200 ->
        {URI.parse(path).path, json_response(conn, 200)}
    end
  end
end

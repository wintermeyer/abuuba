defmodule AbuubaWeb.ActorAdvertisedURLsTest do
  @moduledoc """
  Every URL the actor document hands out answers.

  The document builds its inbox, outbox and follower collections by appending
  to its own id, and the id has two shapes: `/users/:username` for accounts
  born here, `/ap/users/:id` for accounts that came over from a Mastodon
  server with the importer. The router served the appended paths for the first
  shape and not the second, so an imported account advertised an inbox that
  answered 404 -- and a peer that cannot POST to somebody's inbox cannot
  deliver to them at all. Follows from other servers would be accepted and
  their posts would never arrive.

  This is the serializer/router seam, the same shape as the export whose
  importer read a file it never wrote: each side correct alone, never pointed
  at each other. So the test derives the URLs from the document itself rather
  than writing the paths out -- whatever the serializer starts advertising,
  the router has to serve.
  """
  use AbuubaWeb.ConnCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Federation.Actor

  @accept {"accept", "application/activity+json"}

  defp advertised(account) do
    document = Actor.render(account)

    for key <- ~w(id outbox followers following featured featuredTags),
        url = document[key],
        is_binary(url) do
      {key, URI.parse(url).path}
    end
  end

  for scheme <- [:username, :numeric] do
    describe "an account with the #{scheme} id scheme" do
      setup do
        %{account: account_fixture(%{id_scheme: unquote(scheme)})}
      end

      test "every collection its document points at answers", %{
        conn: conn,
        account: account
      } do
        for {key, path} <- advertised(account) do
          status =
            conn
            |> put_req_header(elem(@accept, 0), elem(@accept, 1))
            |> get(path)
            |> Map.get(:status)

          assert status == 200, "#{key} advertised #{path} and it answered #{status}"
        end
      end

      test "and the inbox it names exists", %{conn: conn, account: account} do
        path = URI.parse(Actor.render(account)["inbox"]).path

        status =
          conn
          |> put_req_header("content-type", "application/activity+json")
          |> post(path, "{}")
          |> Map.get(:status)

        # An unsigned empty activity is refused, not unrouted: the difference
        # between "you may not" and "there is nothing here", and a delivering
        # peer retries one and gives up on the other.
        assert status != 404, "the advertised inbox #{path} does not exist"
      end
    end
  end
end

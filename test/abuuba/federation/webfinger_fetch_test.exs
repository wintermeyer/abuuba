defmodule Abuuba.Federation.WebfingerFetchTest do
  @moduledoc """
  What this server accepts when it asks another one who a handle belongs to.

  A WebFinger response is `application/jrd+json` — RFC 7033 says so and every
  implementation sends it. Demanding an ActivityPub content type there means
  refusing every correct answer, which is refusing to look anybody up.
  """

  use Abuuba.DataCase, async: true

  alias Abuuba.Federation.ResolveActor

  @handle "alice@remote.example"
  @actor "https://remote.example/users/alice"

  defp jrd do
    Jason.encode!(%{
      "subject" => "acct:#{@handle}",
      "links" => [
        %{"rel" => "self", "type" => "application/activity+json", "href" => @actor}
      ]
    })
  end

  defp actor_document do
    %{
      "id" => @actor,
      "type" => "Person",
      "preferredUsername" => "alice",
      "inbox" => "#{@actor}/inbox",
      "publicKey" => %{"id" => "#{@actor}#main-key", "owner" => @actor, "publicKeyPem" => "x"}
    }
  end

  # Answers the WebFinger request the way a real server does, and the actor
  # request the way ActivityPub requires.
  # A name that resolves, so the address check the transport sits under has
  # something to approve.
  defp resolver do
    fn
      "remote.example" -> {:ok, [{93, 184, 216, 34}]}
      _other -> {:error, :unresolvable}
    end
  end

  defp transport(webfinger_type) do
    fn _method, url, _headers, _body ->
      if String.contains?(url, "webfinger") do
        {:ok, 200, [{"content-type", webfinger_type}], jrd()}
      else
        {:ok, 200, [{"content-type", "application/activity+json"}],
         Jason.encode!(actor_document())}
      end
    end
  end

  test "a JRD, which is what the specification asks for" do
    assert {:ok, account} =
             ResolveActor.resolve_handle(@handle,
               transport: transport("application/jrd+json; charset=utf-8"),
               resolver: resolver(),
               verify_loopback: false
             )

    assert account.username == "alice"
    assert account.domain == "remote.example"
  end

  test "and plain JSON, which some servers send instead" do
    assert {:ok, account} =
             ResolveActor.resolve_handle("bob@remote.example",
               transport: transport("application/json"),
               resolver: resolver(),
               verify_loopback: false
             )

    assert account.username == "alice"
  end

  test "but not something that is not JSON at all" do
    # The positive control: if the check accepted anything, an HTML error page
    # would be read as an answer.
    assert {:error, _reason} =
             ResolveActor.resolve_handle("carol@remote.example",
               transport: fn _method, _url, _headers, _body ->
                 {:ok, 200, [{"content-type", "text/html"}], "<html>nope</html>"}
               end,
               resolver: resolver(),
               verify_loopback: false
             )
  end
end

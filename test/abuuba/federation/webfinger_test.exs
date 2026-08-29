defmodule Abuuba.Federation.WebFingerTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Federation.URIs
  alias Abuuba.Federation.WebFinger

  defp jrd_for(handle, actor_uri) do
    Jason.encode!(%{
      "subject" => "acct:#{handle}",
      "links" => [
        %{"rel" => "self", "type" => "application/activity+json", "href" => actor_uri}
      ]
    })
  end

  describe "parse_resource/1" do
    test "accepts every spelling people actually paste" do
      assert WebFinger.parse_resource("acct:alice@example.org") == {:ok, "alice", "example.org"}
      assert WebFinger.parse_resource("alice@example.org") == {:ok, "alice", "example.org"}
      assert WebFinger.parse_resource("@alice@example.org") == {:ok, "alice", "example.org"}

      assert WebFinger.parse_resource("  acct:alice@example.org  ") ==
               {:ok, "alice", "example.org"}
    end

    test "refuses anything else rather than guessing" do
      for bad <- ["alice", "acct:alice", "@", "alice@", "@example.org", "", nil, 42] do
        assert WebFinger.parse_resource(bad) == :error, "accepted #{inspect(bad)}"
      end
    end
  end

  describe "the document we serve" do
    test "names the account and points at its actor" do
      account = account_fixture(%{username: "alice"})
      jrd = WebFinger.jrd(account)

      assert jrd["subject"] == "acct:alice@#{URIs.local_domain()}"
      assert {:ok, actor_uri} = WebFinger.self_link(jrd)
      assert actor_uri == Actor.id(account)
    end

    # Against `Actor.id/1`, which is the id the actor is actually served under,
    # rather than against the function that built the link -- comparing it with
    # itself is what let the two drift apart.
    #
    # They have to be the same string. A server in authorized-fetch mode
    # webfingers the handle behind a signature and refuses the request unless
    # the self link loops back to the actor holding the key, so a disagreement
    # here is not untidiness: it is every signed request refused, which for
    # such a peer is everything.
    test "and does so for every shape of local actor" do
      instance_actor = InstanceActor.fetch!()

      accounts = [
        {"an ordinary account", account_fixture(%{username: "ordinary"})},
        {"the instance actor, whose id is not built from its username", instance_actor},
        {"an account on the numeric id scheme",
         account_fixture(%{username: "numeric", id_scheme: :numeric})}
      ]

      for {what, account} <- accounts do
        assert {:ok, self_link} = account |> WebFinger.jrd() |> WebFinger.self_link()

        assert self_link == Actor.id(account),
               "the self link for #{what} does not point at its actor"
      end
    end

    test "carries the profile page and the subscribe template" do
      account = account_fixture(%{username: "alice"})
      links = WebFinger.jrd(account)["links"]

      assert Enum.any?(links, &(&1["rel"] == "http://webfinger.net/rel/profile-page"))
      assert Enum.any?(links, &(&1["rel"] == "http://ostatus.org/schema/1.0/subscribe"))
    end

    test "the subject carries the domain even though the account is local" do
      # The question is being asked by somebody who is not here.
      account = account_fixture(%{username: "alice"})

      assert WebFinger.jrd(account)["subject"] =~ "@#{URIs.local_domain()}"
    end
  end

  describe "self_link/1" do
    test "finds the activity+json self link and nothing else" do
      jrd = %{
        "links" => [
          %{"rel" => "self", "type" => "text/html", "href" => "https://a.example/page"},
          %{
            "rel" => "self",
            "type" => "application/activity+json",
            "href" => "https://a.example/actor"
          }
        ]
      }

      assert WebFinger.self_link(jrd) == {:ok, "https://a.example/actor"}
    end

    test "gives up rather than guessing when there is none" do
      assert WebFinger.self_link(%{"links" => []}) == :error
      assert WebFinger.self_link(%{}) == :error
    end
  end

  describe "lookup/2" do
    test "asks the handle's own domain" do
      fetch = fn url ->
        assert url == WebFinger.webfinger_url("example.org", "alice")
        {:ok, 200, jrd_for("alice@example.org", "https://example.org/users/alice")}
      end

      assert {:ok, jrd} = WebFinger.lookup("alice@example.org", fetch: fetch)
      assert {:ok, "https://example.org/users/alice"} = WebFinger.self_link(jrd)
    end

    test "falls back to the host-meta template on a 404" do
      host_meta = """
      <XRD><Link rel="lrdd" template="https://example.org/wf?resource={uri}"/></XRD>
      """

      fetch = fn url ->
        cond do
          String.contains?(url, "/.well-known/webfinger") ->
            {:ok, 404, ""}

          String.contains?(url, "/.well-known/host-meta") ->
            {:ok, 200, host_meta}

          String.contains?(url, "/wf?resource=") ->
            {:ok, 200, jrd_for("alice@example.org", "https://example.org/users/alice")}
        end
      end

      assert {:ok, jrd} = WebFinger.lookup("alice@example.org", fetch: fetch)
      assert {:ok, "https://example.org/users/alice"} = WebFinger.self_link(jrd)
    end

    test "reports a 410 as gone, not as missing" do
      # A peer can tombstone on gone; on missing it would retry forever.
      fetch = fn _url -> {:ok, 410, ""} end

      assert WebFinger.lookup("alice@example.org", fetch: fetch) == {:error, :gone}
    end

    test "follows exactly one subject redirect" do
      fetch = fn url ->
        cond do
          String.contains?(url, "old.example") ->
            {:ok, 200, jrd_for("alice@new.example", "https://new.example/users/alice")}

          String.contains?(url, "new.example") ->
            {:ok, 200, jrd_for("alice@new.example", "https://new.example/users/alice")}
        end
      end

      assert {:ok, jrd} = WebFinger.lookup("alice@old.example", fetch: fetch)
      assert {:ok, "https://new.example/users/alice"} = WebFinger.self_link(jrd)
    end

    test "refuses to be walked from host to host" do
      fetch = fn url ->
        next = if String.contains?(url, "one.example"), do: "two.example", else: "three.example"

        {:ok, 200, jrd_for("alice@#{next}", "https://#{next}/users/alice")}
      end

      assert WebFinger.lookup("alice@one.example", fetch: fetch) ==
               {:error, :too_many_redirects}
    end

    test "is not confused by a subject in a different case" do
      fetch = fn _url ->
        {:ok, 200, jrd_for("Alice@Example.org", "https://example.org/users/alice")}
      end

      assert {:ok, _jrd} = WebFinger.lookup("alice@example.org", fetch: fetch)
    end

    test "refuses a handle that is not one" do
      assert WebFinger.lookup("nonsense", fetch: fn _ -> {:ok, 200, "{}"} end) ==
               {:error, :malformed}
    end

    test "passes a transport failure back" do
      assert WebFinger.lookup("a@b.example", fetch: fn _ -> {:error, :timeout} end) ==
               {:error, :timeout}
    end
  end

  describe "the loopback check" do
    test "accepts an actor its own domain vouches for" do
      fetch = fn _url ->
        {:ok, 200, jrd_for("alice@example.org", "https://example.org/users/alice")}
      end

      assert WebFinger.verify_loopback(
               "alice@example.org",
               "https://example.org/users/alice",
               fetch: fetch
             ) == :ok
    end

    test "refuses an actor its domain points elsewhere for" do
      # evil.example publishes an actor claiming to be alice@example.org.
      # example.org says alice is somebody else, so the claim is false.
      fetch = fn _url ->
        {:ok, 200, jrd_for("alice@example.org", "https://example.org/users/alice")}
      end

      assert WebFinger.verify_loopback(
               "alice@example.org",
               "https://evil.example/users/alice",
               fetch: fetch
             ) == {:error, :loopback_mismatch}
    end

    test "refuses an actor hosted somewhere other than the handle's domain" do
      # Even if the domain's own WebFinger says so: a lookup that returns an
      # actor on another host is the same forgery one step removed.
      fetch = fn _url ->
        {:ok, 200, jrd_for("alice@example.org", "https://evil.example/users/alice")}
      end

      assert WebFinger.verify_loopback(
               "alice@example.org",
               "https://evil.example/users/alice",
               fetch: fetch
             ) == {:error, :loopback_mismatch}
    end

    test "is not upset by a trailing slash or a capitalised host" do
      fetch = fn _url ->
        {:ok, 200, jrd_for("alice@example.org", "https://Example.org/users/alice/")}
      end

      assert WebFinger.verify_loopback(
               "alice@example.org",
               "https://example.org/users/alice",
               fetch: fetch
             ) == :ok
    end

    test "refuses when the domain answers with nothing usable" do
      fetch = fn _url -> {:ok, 200, ~s({"subject":"acct:alice@example.org"})} end

      assert WebFinger.verify_loopback(
               "alice@example.org",
               "https://example.org/users/alice",
               fetch: fetch
             ) == {:error, :malformed}
    end
  end

  describe "lrdd_template/1" do
    test "reads the template whichever order the attributes are in" do
      assert WebFinger.lrdd_template(
               ~s(<Link rel="lrdd" template="https://a.example/wf?u={uri}"/>)
             ) ==
               {:ok, "https://a.example/wf?u={uri}"}

      assert WebFinger.lrdd_template(
               ~s(<Link template="https://a.example/wf?u={uri}" rel="lrdd"/>)
             ) ==
               {:ok, "https://a.example/wf?u={uri}"}
    end

    test "gives up on a document with no template" do
      assert WebFinger.lrdd_template("<XRD></XRD>") == :error
    end
  end
end

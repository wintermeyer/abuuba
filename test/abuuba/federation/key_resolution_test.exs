defmodule Abuuba.Federation.KeyResolutionTest do
  @moduledoc """
  Finding the key a signature was made with, whatever shape its id takes.

  A signature names the key that made it and nothing else. Which actor that
  belongs to is a question abuuba used to answer by string surgery -- cut the id
  at `#` and the rest is the actor -- which is right for Mastodon's
  `https://host/users/alice#main-key` and wrong for anything else.

  GoToSocial's is a path: `https://host/users/alice/main-key`. Cutting at `#`
  gives back the key's own URL, no account has that as its uri, and every
  delivery from every GoToSocial server was refused with `:unknown_key`. That
  is one of the three largest implementations on the network, unreachable for
  a reason no log line named until the inbox learned to say why.
  """

  use Abuuba.DataCase, async: true

  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Federation.Signature

  @uri "https://remote.example/users/alice"

  defp actor(key_id) do
    %{public_key: pem} = Keypair.generate()

    document = %{
      "id" => @uri,
      "type" => "Person",
      "preferredUsername" => "alice",
      "inbox" => @uri <> "/inbox",
      "publicKey" => %{
        "id" => key_id,
        "owner" => @uri,
        "publicKeyPem" => pem
      }
    }

    {:ok, _account} =
      ResolveActor.resolve(@uri,
        fetch: fn _uri -> {:ok, document} end,
        verify_loopback: false
      )

    pem
  end

  describe "the key behind a signature" do
    test "is found when its id is a fragment, as Mastodon writes it" do
      key_id = @uri <> "#main-key"
      pem = actor(key_id)

      assert Signature.local_key_resolver().(key_id) == {:ok, pem}
    end

    test "is found when its id is a path, as GoToSocial writes it" do
      key_id = @uri <> "/main-key"
      pem = actor(key_id)

      assert Signature.local_key_resolver().(key_id) == {:ok, pem}
    end

    test "is found when its id is neither, because the shape is the peer's to choose" do
      key_id = "https://remote.example/keys/2f8c"
      pem = actor(key_id)

      assert Signature.local_key_resolver().(key_id) == {:ok, pem}
    end

    test "and a key nobody here has ever seen is not found" do
      # The positive control for the three above: if the resolver answered
      # something for anything, they would all pass and mean nothing.
      _pem = actor(@uri <> "#main-key")

      assert Signature.local_key_resolver().("https://elsewhere.example/users/bob#main-key") ==
               :error
    end
  end

  describe "meeting a server for the first time" do
    # Everything above is about a key we already hold. This is the harder half:
    # the very first delivery from a server we have never met, signed with a
    # key we have never seen.
    #
    # Resolving the key id as though it were the actor works when the id is an
    # actor uri plus a fragment, and cannot work otherwise. GoToSocial serves a
    # stub at its key URL with no `inbox`, which abuuba refuses as an actor and
    # is right to -- so first contact failed even after the key ids were being
    # stored, and only worked if something else had happened to resolve that
    # account already.
    defp key_document(key_id, owner) do
      %{
        "id" => owner,
        "type" => "Person",
        "publicKey" => %{
          "id" => key_id,
          "owner" => owner,
          "publicKeyPem" => "-----BEGIN PUBLIC KEY-----\nnot read here\n"
        }
      }
    end

    defp actor_document(pem) do
      %{
        "id" => @uri,
        "type" => "Person",
        "preferredUsername" => "alice",
        "inbox" => @uri <> "/inbox",
        "publicKey" => %{"id" => @uri <> "/main-key", "owner" => @uri, "publicKeyPem" => pem}
      }
    end

    test "follows a path-style key id to the actor that owns it" do
      %{public_key: pem} = Keypair.generate()
      key_id = @uri <> "/main-key"

      fetch = fn
        ^key_id -> {:ok, key_document(key_id, @uri)}
        @uri -> {:ok, actor_document(pem)}
      end

      assert {:ok, account} =
               ResolveActor.resolve_key_owner(key_id, fetch: fetch, verify_loopback: false)

      assert account.uri == @uri
      assert Signature.public_key_of(account) == {:ok, pem}
    end

    test "and a fragment-style one without asking anybody" do
      %{public_key: pem} = Keypair.generate()
      key_id = @uri <> "#main-key"

      fetch = fn
        @uri -> {:ok, actor_document(pem)}
        other -> flunk("fetched #{other}; the actor is named in the key id")
      end

      assert {:ok, account} =
               ResolveActor.resolve_key_owner(key_id, fetch: fetch, verify_loopback: false)

      assert account.uri == @uri
    end

    test "and refuses a key that claims to belong to another host" do
      # A document speaks for its own server and no other. Without this, any
      # server could hand us a key claiming to be somebody else's and have us
      # go and fetch that somebody.
      key_id = "https://evil.example/keys/1"

      fetch = fn
        ^key_id -> {:ok, key_document(key_id, @uri)}
        other -> flunk("fetched #{other} for a key from another host")
      end

      assert {:error, _reason} =
               ResolveActor.resolve_key_owner(key_id, fetch: fetch, verify_loopback: false)
    end
  end
end

defmodule Abuuba.Federation.InstanceActorKeyTest do
  use Abuuba.DataCase, async: true

  alias Abuuba.Federation.ResolveActor

  @document %{
    "id" => "https://mastodon.interop/actor",
    "type" => "Application",
    "preferredUsername" => "mastodon.interop",
    "inbox" => "https://mastodon.interop/actor/inbox",
    "url" => "https://mastodon.interop/about/more",
    "publicKey" => %{
      "id" => "https://mastodon.interop/actor#main-key",
      "owner" => "https://mastodon.interop/actor",
      "publicKeyPem" => "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----\n"
    }
  }

  test "a local account still cannot have a dotted username" do
    # The control, and the half that must not move: the latitude is for
    # somebody else's naming, not for ours. Without this the fix reads as
    # "stop validating usernames".
    assert {:error, changeset} =
             Abuuba.Accounts.create_account(%{username: "not.allowed.here"})

    assert %{username: [_message]} = errors_on(changeset)
  end

  test "a peer's ordinary account may have one, because their server said so" do
    assert {:ok, account} =
             Abuuba.Accounts.create_account(%{
               username: "with.dots",
               domain: "remote.example",
               uri: "https://remote.example/users/withdots",
               inbox_url: "https://remote.example/users/withdots/inbox"
             })

    assert account.username == "with.dots"
  end

  test "but a name that is only punctuation is still refused", %{} do
    # Laxer than the reference implementation would let a peer name an account
    # something that renders as a handle nobody can read or repeat.
    for nonsense <- ["..", "-", "alice.", ".alice"] do
      assert {:error, changeset} =
               Abuuba.Accounts.create_account(%{
                 username: nonsense,
                 domain: "remote.example",
                 uri: "https://remote.example/users/#{Base.encode16(nonsense)}",
                 inbox_url: "https://remote.example/inbox"
               })

      assert %{username: [_message]} = errors_on(changeset), "accepted #{inspect(nonsense)}"
    end
  end

  test "a peer whose domain runs long is still storable" do
    # Thirty characters is our rule for our own names. An instance actor is
    # named after its server, and plenty of domains are longer than that --
    # refusing them is refusing that server's forwarded reports, which is the
    # same bug arriving by a different door.
    long = "mastodon.a-rather-long-community-domain.example"
    assert String.length(long) > 30

    assert {:ok, account} =
             Abuuba.Accounts.create_account(%{
               username: long,
               domain: "a-rather-long-community-domain.example",
               actor_type: :application,
               uri: "https://#{long}/actor",
               inbox_url: "https://#{long}/actor/inbox"
             })

    assert account.username == long
  end

  test "while our own names are still held to thirty" do
    # The control: the latitude is for names this server did not choose.
    assert {:error, changeset} =
             Abuuba.Accounts.create_account(%{username: String.duplicate("a", 31)})

    assert %{username: [_message]} = errors_on(changeset)
  end

  test "and a name longer than the column is refused rather than crashing" do
    # The column is varchar(255). A validation that allowed more would hand
    # Postgres a 22001 on the untrusted path: a 500 where a 422 belongs.
    assert {:error, changeset} =
             Abuuba.Accounts.create_account(%{
               username: String.duplicate("a", 256),
               domain: "remote.example",
               uri: "https://remote.example/users/long",
               inbox_url: "https://remote.example/inbox"
             })

    assert %{username: [_message]} = errors_on(changeset)
  end

  test "a peer's instance actor can be resolved by its key id" do
    result =
      ResolveActor.resolve_key_owner("https://mastodon.interop/actor#main-key",
        fetch: fn _uri -> {:ok, @document} end,
        verify_loopback: false
      )

    assert {:ok, account} = result
    assert account.uri == "https://mastodon.interop/actor"
  end
end

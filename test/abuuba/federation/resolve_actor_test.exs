defmodule Abuuba.Federation.ResolveActorTest do
  use Abuuba.DataCase, async: true

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.DomainBudget
  alias Abuuba.Federation.ResolveActor

  @uri "https://remote.example/users/alice"

  defp actor_document(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => @uri,
        "type" => "Person",
        "preferredUsername" => "alice",
        "name" => "Alice",
        "summary" => "hello",
        "inbox" => "https://remote.example/users/alice/inbox",
        "url" => "https://remote.example/@alice"
      },
      overrides
    )
  end

  defp webfinger_document do
    Jason.encode!(%{
      "subject" => "acct:alice@remote.example",
      "links" => [
        %{"rel" => "self", "type" => "application/activity+json", "href" => @uri}
      ]
    })
  end

  defp resolve(document, opts \\ []) do
    fetcher = Keyword.get(opts, :fetch, fn _uri -> {:ok, document} end)

    ResolveActor.resolve(
      Keyword.get(opts, :uri, @uri),
      Keyword.merge([fetch: fetcher, verify_loopback: false], opts)
    )
  end

  describe "resolving whatever somebody typed" do
    test "a handle is asked about at the server it names" do
      # The thing search with resolve=true is handed most often, and the thing
      # that used to be pushed through the address path and answered "no such
      # person" about somebody plainly there.
      webfinger = fn _url -> {:ok, 200, webfinger_document()} end

      assert {:ok, %Account{} = account} =
               ResolveActor.resolve_query("alice@remote.example",
                 fetch: fn _uri -> {:ok, actor_document()} end,
                 webfinger_fetch: webfinger,
                 verify_loopback: false
               )

      assert account.username == "alice"
      assert account.domain == "remote.example"
    end

    test "with the @ in front that everybody writes" do
      webfinger = fn url ->
        # And it arrives without one, because that is not part of a handle:
        # the address asked about names `acct:alice@remote.example`.
        refute String.contains?(url, "acct:@")

        {:ok, 200, webfinger_document()}
      end

      assert {:ok, %Account{}} =
               ResolveActor.resolve_query("@alice@remote.example",
                 fetch: fn _uri -> {:ok, actor_document()} end,
                 webfinger_fetch: webfinger,
                 verify_loopback: false
               )
    end

    test "an address is still fetched as an address" do
      # The positive control for the branch: if everything went down the handle
      # path, this would ask WebFinger about a URL and fail.
      assert {:ok, %Account{} = account} =
               ResolveActor.resolve_query(@uri,
                 fetch: fn _uri -> {:ok, actor_document()} end,
                 webfinger_fetch: fn _handle -> flunk("a URL was treated as a handle") end,
                 verify_loopback: false
               )

      assert account.username == "alice"
    end

    test "and a URL with an @ in the path is not a handle" do
      assert {:ok, %Account{}} =
               ResolveActor.resolve_query("https://remote.example/@alice",
                 fetch: fn _uri -> {:ok, actor_document()} end,
                 webfinger_fetch: fn _handle -> flunk("a URL was treated as a handle") end,
                 verify_loopback: false
               )
    end
  end

  describe "what the search endpoint may go and fetch" do
    test "an address, and a complete handle" do
      assert ResolveActor.resolvable?("https://remote.example/users/alice")
      assert ResolveActor.resolvable?("alice@remote.example")
      assert ResolveActor.resolvable?("@alice@remote.example")
    end

    test "and nothing else, because everything else is a text search" do
      # The gate this exists for: search sent handles to the database and only
      # addresses to the resolver, so `resolve=true` never reached this module
      # for the one thing people paste most. Widening it to anything at all
      # would make every search a fetch.
      refute ResolveActor.resolvable?("alice")
      refute ResolveActor.resolvable?("some words")
      refute ResolveActor.resolvable?("")
      refute ResolveActor.resolvable?(nil)
    end
  end

  describe "a well-formed actor" do
    test "becomes an account" do
      assert {:ok, %Account{} = account} = resolve(actor_document())

      assert account.username == "alice"
      assert account.domain == "remote.example"
      assert account.uri == @uri
      assert account.display_name == "Alice"
      assert account.note == "hello"
      assert account.inbox_url == "https://remote.example/users/alice/inbox"
      refute Account.local?(account)
      refute is_nil(account.last_fetched_at)
    end

    test "keeps the endpoints and flags a peer published" do
      document =
        actor_document(%{
          "outbox" => "https://remote.example/users/alice/outbox",
          "followers" => "https://remote.example/users/alice/followers",
          "following" => "https://remote.example/users/alice/following",
          "endpoints" => %{"sharedInbox" => "https://remote.example/inbox"},
          "manuallyApprovesFollowers" => true,
          "discoverable" => true,
          "indexable" => true,
          "memorial" => true,
          "alsoKnownAs" => ["https://old.example/users/alice"]
        })

      {:ok, account} = resolve(document)

      assert account.shared_inbox_url == "https://remote.example/inbox"
      assert account.outbox_url == "https://remote.example/users/alice/outbox"
      assert account.locked
      assert account.discoverable
      assert account.indexable
      # Somebody else's server saying one of its people has died. abuuba has the
      # column, the moderator action and the API field for it already, and was
      # the only part of that chain that never asked or answered over the wire.
      assert account.memorial
      assert account.also_known_as == ["https://old.example/users/alice"]
    end

    test "takes only PropertyValue attachments as profile fields" do
      # The same key carries images on a post, so taking everything would file
      # a picture as a profile field.
      document =
        actor_document(%{
          "attachment" => [
            %{"type" => "PropertyValue", "name" => "Web", "value" => "https://a.example"},
            %{"type" => "Image", "url" => "https://a.example/pic.png"},
            %{"type" => "PropertyValue", "name" => "", "value" => "empty name"}
          ]
        })

      {:ok, account} = resolve(document)

      assert [%{name: "Web", value: "https://a.example"}] = account.fields
    end

    test "keeps up to fifty fields, which is what a remote account is allowed" do
      # Four is the limit on what somebody may put on their own profile here.
      # Applying it to a remote actor would silently drop what another server
      # legitimately published and show the account differently from every
      # other client.
      fields =
        for i <- 1..80, do: %{"type" => "PropertyValue", "name" => "k#{i}", "value" => "v#{i}"}

      {:ok, account} = resolve(actor_document(%{"attachment" => fields}))

      assert length(account.fields) == 50
    end

    test "keeps a long display name instead of refusing the actor" do
      # Thirty characters is our own limit on what somebody may call
      # themselves here. Enforcing it on a remote actor meant refusing to
      # federate with anybody whose name was longer, which is most people with
      # an emoji in it.
      name = String.duplicate("a", 200)

      assert {:ok, account} = resolve(actor_document(%{"name" => name}))
      assert account.display_name == name
    end

    test "keeps a long bio, cut at the length the reference implementation uses" do
      assert {:ok, account} = resolve(actor_document(%{"summary" => String.duplicate("b", 900)}))

      assert byte_size(account.note) == 900
    end

    test "cuts a name that no reader could want" do
      assert {:ok, account} = resolve(actor_document(%{"name" => String.duplicate("a", 5_000)}))

      assert String.length(account.display_name) == 2_048
    end

    test "marks a Service actor as a bot" do
      {:ok, account} = resolve(actor_document(%{"type" => "Service"}))

      assert account.actor_type == :service
      assert account.bot
    end

    test "accepts every actor type the fediverse uses" do
      for {type, expected} <- [
            {"Person", :person},
            {"Service", :service},
            {"Application", :application},
            {"Group", :group},
            {"Organization", :organization}
          ] do
        uri = "https://remote.example/users/#{expected}"

        {:ok, account} =
          resolve(
            actor_document(%{
              "id" => uri,
              "type" => type,
              "preferredUsername" => to_string(expected)
            }),
            uri: uri
          )

        assert account.actor_type == expected
      end
    end

    test "stores the public key as a keypair with no private half" do
      pem = "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----"

      {:ok, account} =
        resolve(actor_document(%{"publicKey" => %{"publicKeyPem" => pem, "id" => @uri <> "#k"}}))

      keypair = Repo.get_by(Abuuba.Accounts.Keypair, account_id: account.id)

      assert keypair.public_key == pem
      assert keypair.private_key == nil, "we can verify with a remote key, never sign"
    end

    test "replaces a rotated key rather than keeping both" do
      # Keeping the old one would let a compromised key keep verifying.
      first = "-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----"
      second = "-----BEGIN PUBLIC KEY-----\nBBB\n-----END PUBLIC KEY-----"

      {:ok, _} = resolve(actor_document(%{"publicKey" => %{"publicKeyPem" => first}}))

      {:ok, account} =
        ResolveActor.refresh(@uri,
          fetch: fn _ -> {:ok, actor_document(%{"publicKey" => %{"publicKeyPem" => second}})} end,
          verify_loopback: false
        )

      keys =
        Repo.all(
          Ecto.Query.from(k in Abuuba.Accounts.Keypair, where: k.account_id == ^account.id)
        )

      assert [%{public_key: ^second}] = keys
    end
  end

  describe "documents we refuse" do
    test "one that is not an actor" do
      assert resolve(actor_document(%{"type" => "Note"})) == {:error, :not_an_actor}
    end

    test "one with no inbox, which cannot be delivered to" do
      # Storing it means a follow that silently goes nowhere.
      document = actor_document() |> Map.delete("inbox")

      assert resolve(document) == {:error, :actor_without_inbox}
    end

    test "one with no username" do
      document = actor_document() |> Map.delete("preferredUsername")

      assert resolve(document) == {:error, :actor_without_username}
    end

    test "one describing an actor on another host" do
      # evil.example must not be able to hand back a document claiming to be
      # somebody on good.example.
      document = actor_document(%{"id" => "https://good.example/users/alice"})

      assert resolve(document, uri: "https://evil.example/users/alice") ==
               {:error, :actor_host_mismatch}
    end

    test "one fetched over plain HTTP" do
      assert resolve(actor_document(), uri: "http://remote.example/users/alice") ==
               {:error, :insecure_actor_uri}
    end

    test "one that is not a document at all" do
      assert resolve("not json") == {:error, :malformed_actor}
    end

    test "a fetch that failed" do
      assert resolve(nil, fetch: fn _ -> {:error, :timeout} end) == {:error, :timeout}
    end
  end

  describe "the loopback check" do
    test "is run unless a caller says otherwise" do
      # The handle plus the host is a claim; the loopback check is what makes
      # it true.
      webfinger = fn _url ->
        {:ok, 200,
         Jason.encode!(%{
           "subject" => "acct:alice@remote.example",
           "links" => [
             %{
               "rel" => "self",
               "type" => "application/activity+json",
               "href" => "https://remote.example/users/somebody-else"
             }
           ]
         })}
      end

      assert ResolveActor.resolve(@uri,
               fetch: fn _ -> {:ok, actor_document()} end,
               webfinger_fetch: webfinger
             ) == {:error, :loopback_mismatch}
    end

    test "passes when the domain vouches for the handle" do
      webfinger = fn _url ->
        {:ok, 200,
         Jason.encode!(%{
           "subject" => "acct:alice@remote.example",
           "links" => [
             %{"rel" => "self", "type" => "application/activity+json", "href" => @uri}
           ]
         })}
      end

      assert {:ok, _account} =
               ResolveActor.resolve(@uri,
                 fetch: fn _ -> {:ok, actor_document()} end,
                 webfinger_fetch: webfinger
               )
    end
  end

  describe "renames" do
    test "an actor keeping its URI and changing its name is the same account" do
      {:ok, first} = resolve(actor_document())

      {:ok, second} =
        ResolveActor.refresh(@uri,
          fetch: fn _ -> {:ok, actor_document(%{"preferredUsername" => "alicia"})} end,
          verify_loopback: false
        )

      assert second.id == first.id
      assert second.username == "alicia"
    end

    test "a handle now pointing at a different URI follows the handle" do
      # The remote host deleted an account and made a new one with the same
      # name. There cannot be two rows: a handle is unique per host, the unique
      # index says so, and their WebFinger has just told us who holds it now.
      {:ok, original} = resolve(actor_document())

      other_uri = "https://remote.example/users/alice-2"

      {:ok, updated} = resolve(actor_document(%{"id" => other_uri}), uri: other_uri)

      assert updated.id == original.id
      assert updated.uri == other_uri
      assert Repo.aggregate(Account, :count) == 1
    end
  end

  describe "freshness" do
    test "an account fetched recently is not fetched again" do
      {:ok, _} = resolve(actor_document())

      {:ok, account} =
        ResolveActor.resolve(@uri,
          fetch: fn _ -> flunk("should not have re-fetched") end,
          verify_loopback: false
        )

      assert account.username == "alice"
    end

    test "an account fetched long ago is fetched again" do
      {:ok, account} = resolve(actor_document())

      Repo.update!(
        Ecto.Changeset.change(account,
          last_fetched_at: DateTime.add(DateTime.utc_now(), -2, :day)
        )
      )

      {:ok, refreshed} =
        ResolveActor.resolve(@uri,
          fetch: fn _ -> {:ok, actor_document(%{"name" => "Alice Again"})} end,
          verify_loopback: false
        )

      assert refreshed.display_name == "Alice Again"
    end

    test "a failed refresh keeps what we already had" do
      # The peer may be down; the account still exists.
      {:ok, account} = resolve(actor_document())

      Repo.update!(
        Ecto.Changeset.change(account,
          last_fetched_at: DateTime.add(DateTime.utc_now(), -2, :day)
        )
      )

      assert {:ok, kept} =
               ResolveActor.resolve(@uri,
                 fetch: fn _ -> {:error, :timeout} end,
                 verify_loopback: false
               )

      assert kept.id == account.id
      assert kept.display_name == "Alice"
    end
  end

  describe "the domain budget" do
    test "counts subdomains against their registrable domain" do
      assert DomainBudget.registrable_domain("a.evil.example") == "evil.example"
      assert DomainBudget.registrable_domain("b.c.evil.example") == "evil.example"
      assert DomainBudget.registrable_domain("evil.example") == "evil.example"
      assert DomainBudget.registrable_domain("a.example.co.uk") == "example.co.uk"
    end

    test "stops a host introducing unlimited subdomains" do
      for i <- 1..DomainBudget.max_subdomains() do
        uri = "https://sub#{i}.spam.example/users/alice"

        assert {:ok, _} =
                 resolve(actor_document(%{"id" => uri}), uri: uri),
               "subdomain #{i} should have been within budget"
      end

      over = "https://one-too-many.spam.example/users/alice"

      assert resolve(actor_document(%{"id" => over}), uri: over) ==
               {:error, :domain_budget_exhausted}
    end

    test "does not spend budget refreshing an actor we already hold" do
      {:ok, _} = resolve(actor_document())
      spent = DomainBudget.spent("remote.example")

      {:ok, _} =
        ResolveActor.refresh(@uri,
          fetch: fn _ -> {:ok, actor_document()} end,
          verify_loopback: false
        )

      assert DomainBudget.spent("remote.example") == spent
    end

    test "keeps one host's budget away from another" do
      for i <- 1..DomainBudget.max_subdomains() do
        uri = "https://sub#{i}.spam.example/users/alice"
        resolve(actor_document(%{"id" => uri}), uri: uri)
      end

      other = "https://fine.example/users/bob"

      assert {:ok, _} =
               resolve(actor_document(%{"id" => other, "preferredUsername" => "bob"}), uri: other)
    end
  end

  describe "what is held while a stranger's server answers" do
    test "not a database connection" do
      # The fetch used to run inside `Repo.transaction`, so one of ten pool
      # connections was held for as long as the remote took to answer -- up to
      # fifteen seconds of connect and receive timeout. A peer sending
      # activities that name actors on a host which accepts connections and
      # never replies could occupy the pool and stall every other query on the
      # server. It showed up first as a test that lost its connection mid-DNS
      # and took five unrelated tests down with it.
      me = self()

      fetcher = fn _uri ->
        send(me, {:in_transaction?, Abuuba.Repo.in_transaction?()})

        {:ok, actor_document()}
      end

      assert {:ok, _account} = resolve(actor_document(), fetch: fetcher)

      assert_received {:in_transaction?, false}
    end

    test "and a refresh holds none either" do
      {:ok, _} = resolve(actor_document())
      me = self()

      fetcher = fn _uri ->
        send(me, {:in_transaction?, Abuuba.Repo.in_transaction?()})

        {:ok, actor_document()}
      end

      assert {:ok, _account} =
               ResolveActor.refresh(@uri, fetch: fetcher, verify_loopback: false)

      assert_received {:in_transaction?, false}
    end
  end

  describe "concurrent resolution" do
    test "two resolutions of the same new actor produce one account" do
      # Two requests mentioning the same new actor arrive together constantly.
      uri = "https://remote.example/users/racy"
      document = actor_document(%{"id" => uri, "preferredUsername" => "racy"})

      results =
        for _ <- 1..2 do
          resolve(document, uri: uri)
        end

      assert Enum.all?(results, &match?({:ok, _}, &1))

      ids = Enum.map(results, fn {:ok, account} -> account.id end)
      assert length(Enum.uniq(ids)) == 1

      assert Accounts.get_account_by_handle("racy", "remote.example")
    end
  end
end

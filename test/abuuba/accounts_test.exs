defmodule Abuuba.AccountsTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Keypair
  alias Abuuba.Accounts.User
  alias Abuuba.Snowflake

  describe "create_account/1" do
    test "a local account has no domain" do
      account = account_fixture(%{username: "alice"})

      assert account.domain == nil
      assert Account.local?(account)
      assert Account.acct(account) == "alice"
    end

    test "a remote account carries its host" do
      account = remote_account_fixture(%{username: "bob", domain: "remote.example"})

      refute Account.local?(account)
      assert Account.acct(account) == "bob@remote.example"
    end

    test "takes its id from the database, in the snowflake range" do
      account = account_fixture()

      assert account.id > 0

      assert DateTime.diff(Snowflake.to_time(account.id), DateTime.utc_now(), :second) |> abs() <
               60
    end

    test "ids order by creation" do
      first = account_fixture()
      second = account_fixture()

      assert first.id < second.id
    end

    test "requires a username" do
      assert {:error, changeset} = Accounts.create_account(%{})
      assert "can't be blank" in errors_on(changeset).username
    end

    test "refuses a username that would need escaping in a URL" do
      for bad <- ["with space", "a/b", "a.b", "a@b", "wintermeyer!", "ümlaut", "a%20b"] do
        assert {:error, changeset} = Accounts.create_account(%{username: bad})
        assert errors_on(changeset).username != []
      end
    end

    test "refuses a username longer than 30 characters" do
      assert {:error, changeset} =
               Accounts.create_account(%{username: String.duplicate("a", 31)})

      assert "should be at most 30 character(s)" in errors_on(changeset).username
    end

    test "treats an empty domain as local rather than as a host named nothing" do
      for blank <- ["", "   "] do
        {:ok, account} = Accounts.create_account(%{username: unique_username(), domain: blank})

        assert account.domain == nil
        assert Account.local?(account)
      end
    end

    test "normalises the host, because a hostname has no case and no spaces" do
      account = remote_account_fixture(%{username: "bob", domain: " Remote.Example "})

      assert account.domain == "remote.example"
      assert Account.acct(account) == "bob@remote.example"
    end
  end

  describe "the username/domain uniqueness rule" do
    test "two local accounts cannot share a username" do
      account_fixture(%{username: "alice"})

      assert {:error, changeset} = Accounts.create_account(%{username: "alice"})
      assert "has already been taken" in errors_on(changeset).username
    end

    test "is case-insensitive, because handles are" do
      account_fixture(%{username: "alice"})

      assert {:error, changeset} = Accounts.create_account(%{username: "ALICE"})
      assert "has already been taken" in errors_on(changeset).username
    end

    test "the same username on two different hosts is two different people" do
      account_fixture(%{username: "alice"})
      remote_account_fixture(%{username: "alice", domain: "one.example"})

      assert {:ok, _} =
               Accounts.create_account(%{username: "alice", domain: "two.example"})
    end

    test "is case-insensitive on the domain too" do
      remote_account_fixture(%{username: "alice", domain: "One.Example"})

      assert {:error, changeset} =
               Accounts.create_account(%{username: "alice", domain: "one.example"})

      assert "has already been taken" in errors_on(changeset).username
    end
  end

  describe "get_account_by_handle/2" do
    test "finds a local account whatever the case" do
      account = account_fixture(%{username: "Alice"})

      assert Accounts.get_account_by_handle("alice").id == account.id
      assert Accounts.get_account_by_handle("ALICE").id == account.id
    end

    test "finds a remote account by handle and host" do
      account = remote_account_fixture(%{username: "bob", domain: "Remote.Example"})

      assert Accounts.get_account_by_handle("bob", "remote.example").id == account.id
    end

    test "does not confuse a local account with a remote one of the same name" do
      local = account_fixture(%{username: "alice"})
      remote = remote_account_fixture(%{username: "alice", domain: "remote.example"})

      assert Accounts.get_account_by_handle("alice").id == local.id
      assert Accounts.get_account_by_handle("alice", "remote.example").id == remote.id
    end

    test "returns nil when nobody matches" do
      assert Accounts.get_account_by_handle("nobody") == nil
    end
  end

  describe "get_accounts/1" do
    test "hands back a map keyed by id, skipping ids that are nobody" do
      alice = account_fixture()
      bob = account_fixture()

      found = Accounts.get_accounts([alice.id, bob.id, 0])

      assert Map.keys(found) |> Enum.sort() == Enum.sort([alice.id, bob.id])
      assert found[alice.id].id == alice.id
    end
  end

  describe "profile fields" do
    test "accepts up to four" do
      fields = for i <- 1..4, do: %{name: "key#{i}", value: "value#{i}"}
      account = account_fixture(%{fields: fields})

      assert length(account.fields) == 4
      assert Enum.map(account.fields, & &1.name) == ~w(key1 key2 key3 key4)
    end

    test "refuses a fifth" do
      fields = for i <- 1..5, do: %{name: "key#{i}", value: "value#{i}"}

      assert {:error, changeset} =
               Accounts.create_account(%{username: unique_username(), fields: fields})

      assert errors_on(changeset).fields != []
    end

    test "requires both halves of a field" do
      assert {:error, changeset} =
               Accounts.create_account(%{
                 username: unique_username(),
                 fields: [%{name: "key"}]
               })

      assert errors_on(changeset).fields != []
    end
  end

  describe "profile_changeset/2" do
    test "lets a person edit what is theirs to edit" do
      account = account_fixture()

      changeset =
        Account.profile_changeset(account, %{
          display_name: "Alice",
          note: "hello",
          fields: [%{name: "web", value: "https://example.com"}]
        })

      assert {:ok, updated} = Repo.update(changeset)
      assert updated.display_name == "Alice"
      assert [%{name: "web"}] = updated.fields
    end

    test "cannot lift a suspension" do
      account = account_fixture(%{suspended_at: DateTime.utc_now()})

      {:ok, updated} = Account.profile_changeset(account, %{suspended_at: nil}) |> Repo.update()

      refute is_nil(updated.suspended_at)
    end

    test "cannot rename the account or move it to another host" do
      account = account_fixture(%{username: "alice"})

      {:ok, updated} =
        Account.profile_changeset(account, %{username: "bob", domain: "elsewhere.example"})
        |> Repo.update()

      assert updated.username == "alice"
      assert updated.domain == nil
    end

    test "cannot award itself a verified link" do
      # Verification means this server fetched the URL and found a rel=me
      # pointing back. Only the server may assert that.
      account = account_fixture()
      at = DateTime.utc_now()

      {:ok, updated} =
        Account.profile_changeset(account, %{
          fields: [%{name: "web", value: "https://example.com", verified_at: at}]
        })
        |> Repo.update()

      assert [%{verified_at: nil}] = updated.fields
    end

    test "an explicit null validates rather than crashing the database" do
      # A JSON body may carry `"display_name": null`, and these columns are
      # NOT NULL. Reaching Postgres with it is a 500, not a 422.
      account = account_fixture()

      for field <- [:display_name, :note, :locked, :bot, :discoverable, :indexable] do
        changeset = Account.profile_changeset(account, %{field => nil})

        refute changeset.valid?, "#{field} accepted a null"
      end
    end

    test "cannot repoint the federation endpoints" do
      account = remote_account_fixture()
      original = account.inbox_url

      {:ok, updated} =
        Account.profile_changeset(account, %{inbox_url: "https://attacker.example/inbox"})
        |> Repo.update()

      assert updated.inbox_url == original
    end
  end

  describe "moderation state" do
    test "is recorded as when, not whether" do
      at = DateTime.utc_now()
      account = account_fixture(%{suspended_at: at, silenced_at: at, sensitized_at: at})

      assert account.suspended_at == at
      assert account.silenced_at == at
      assert account.sensitized_at == at
    end

    test "is absent by default" do
      account = account_fixture()

      assert account.suspended_at == nil
      assert account.silenced_at == nil
      assert account.sensitized_at == nil
    end

    test "survives a round trip to the database with its microseconds" do
      # Asserting on the struct create_account returned would pass even if the
      # column truncated to whole seconds.
      at = DateTime.utc_now()
      account = account_fixture(%{suspended_at: at, fields: [%{name: "a", value: "b"}]})

      reloaded = Repo.get!(Account, account.id)

      assert reloaded.suspended_at == at
      assert [%{name: "a", value: "b"}] = reloaded.fields
      assert reloaded.actor_type == :person
    end

    test "a moderator sets it, and only it" do
      account = account_fixture(%{username: "alice"})
      at = DateTime.utc_now()

      assert {:ok, updated} =
               Accounts.update_moderation(account, %{suspended_at: at, username: "bob"})

      assert updated.suspended_at == at
      assert updated.username == "alice"
    end
  end

  describe "account migration" do
    test "points at the account it moved to and keeps its old handles" do
      target = account_fixture()

      account =
        account_fixture(%{
          moved_to_account_id: target.id,
          also_known_as: ["https://old.example/users/alice"]
        })

      assert account.moved_to_account_id == target.id
      assert account.also_known_as == ["https://old.example/users/alice"]
    end

    test "forgets the pointer when the target is deleted" do
      target = account_fixture()
      account = account_fixture(%{moved_to_account_id: target.id})

      Repo.delete!(target)

      assert Repo.get!(Account, account.id).moved_to_account_id == nil
    end

    test "refuses to point at an account that does not exist" do
      assert {:error, changeset} =
               Accounts.create_account(%{
                 username: unique_username(),
                 moved_to_account_id: 123_456_789
               })

      assert errors_on(changeset).moved_to_account_id != []
    end
  end

  describe "the reserved id range" do
    test "an internal actor sits below zero" do
      assert Accounts.instance_actor_id() < 0
      assert Accounts.internal_actor_id?(Accounts.instance_actor_id())
      refute Accounts.internal_actor_id?(account_fixture().id)
    end

    test "an internal actor may be created with its fixed id and a hostname for a name" do
      assert {:ok, actor} =
               Accounts.create_internal_actor(%{
                 id: Accounts.instance_actor_id(),
                 username: "abuuba.example",
                 actor_type: :application
               })

      assert actor.id == Accounts.instance_actor_id()
      assert actor.actor_type == :application
      assert Accounts.get_account(Accounts.instance_actor_id()).id == actor.id
    end

    test "an internal actor cannot be remote" do
      # An id in the reserved range names an actor this server owns. One with a
      # domain would be somebody else's.
      assert {:error, changeset} =
               Accounts.create_internal_actor(%{
                 id: -1234,
                 username: "impostor",
                 domain: "elsewhere.example"
               })

      assert errors_on(changeset).domain != []
    end

    test "an internal actor cannot be given an id in the ordinary range" do
      assert {:error, changeset} =
               Accounts.create_internal_actor(%{id: 1234, username: "abuuba.example"})

      assert errors_on(changeset).id != []
    end

    test "the database refuses a remote actor in the reserved range even so" do
      # The changeset is the polite guard; this is the one that holds if some
      # future code path writes the row without going through it.
      assert_raise Postgrex.Error, ~r/accounts_internal_actors_are_local/, fn ->
        Repo.query!(
          "INSERT INTO accounts (id, username, domain, inserted_at, updated_at) " <>
            "VALUES (-1234, 'impostor', 'elsewhere.example', now(), now())"
        )
      end
    end

    test "the database refuses a domain that is present but empty" do
      assert_raise Postgrex.Error, ~r/accounts_domain_is_null_or_present/, fn ->
        Repo.query!(
          "INSERT INTO accounts (id, username, domain, inserted_at, updated_at) " <>
            "VALUES (1, 'ghost', '', now(), now())"
        )
      end
    end

    test "ordinary account creation cannot choose its own id" do
      # Mass assignment of a primary key is how one account overwrites another.
      account = account_fixture(%{id: -5})

      refute account.id == -5
      assert account.id > 0
    end
  end

  describe "users" do
    test "belong to an account one to one" do
      account = account_fixture()
      user = user_fixture(%{account_id: account.id, email: "alice@example.com"})

      assert user.account_id == account.id
      assert Accounts.get_user_by_account(account).id == user.id
    end

    test "cannot be created twice for one account" do
      account = account_fixture()
      user_fixture(%{account_id: account.id})

      assert {:error, changeset} =
               Accounts.create_user(%{account_id: account.id, email: unique_email()})

      assert errors_on(changeset).account_id != []
    end

    test "have a unique email, case-insensitively" do
      user_fixture(%{email: "Alice@Example.com"})

      assert {:error, changeset} =
               Accounts.create_user(%{
                 account_id: account_fixture().id,
                 email: "alice@example.com"
               })

      assert "has already been taken" in errors_on(changeset).email
    end

    test "reject an address that is not one" do
      for bad <- ["nope", "a@b", "a b@example.com", "@example.com", "a@,b.com"] do
        assert {:error, changeset} =
                 Accounts.create_user(%{account_id: account_fixture().id, email: bad})

        assert errors_on(changeset).email != []
      end
    end

    test "start unconfirmed and unapproved" do
      user = user_fixture()

      refute User.confirmed?(user)
      refute user.approved
    end

    test "are removed with their account" do
      account = account_fixture()
      user_fixture(%{account_id: account.id})

      Repo.delete!(account)

      assert Accounts.get_user_by_account(account.id) == nil
    end

    test "do not exist for remote actors" do
      assert Accounts.get_user_by_account(remote_account_fixture()) == nil
    end
  end

  describe "keypairs" do
    test "generate a 2048-bit RSA key in the PEM forms the fediverse expects" do
      %{public_key: public, private_key: private, type: type} = Keypair.generate()

      assert type == :rsa_2048
      assert public =~ "-----BEGIN PUBLIC KEY-----"
      assert private =~ "-----BEGIN RSA PRIVATE KEY-----"

      [entry] = :public_key.pem_decode(public)
      {:RSAPublicKey, modulus, _exponent} = :public_key.pem_entry_decode(entry)

      assert modulus |> :binary.encode_unsigned() |> byte_size() == 256
    end

    test "the public half really belongs to the private half" do
      %{public_key: public, private_key: private} = Keypair.generate()

      [public_entry] = :public_key.pem_decode(public)
      [private_entry] = :public_key.pem_decode(private)

      message = "sign me"
      signature = :public_key.sign(message, :sha256, :public_key.pem_entry_decode(private_entry))

      assert :public_key.verify(
               message,
               :sha256,
               signature,
               :public_key.pem_entry_decode(public_entry)
             )
    end

    test "are stored for an account and read back intact" do
      account = account_fixture()

      assert {:ok, keypair} = Accounts.create_keypair(account)
      assert keypair.account_id == account.id
      assert Keypair.active?(keypair)

      reloaded = Accounts.active_keypair(account)
      assert reloaded.private_key == keypair.private_key
      assert reloaded.public_key == keypair.public_key
    end

    test "never touch the disk in the clear" do
      account = account_fixture()
      {:ok, keypair} = Accounts.create_keypair(account)

      %{rows: [[stored]]} =
        Repo.query!("SELECT private_key FROM keypairs WHERE account_id = $1", [account.id])

      refute stored == keypair.private_key
      refute stored =~ "PRIVATE KEY"
      assert is_binary(stored)
    end

    test "the public half is not encrypted, since everyone is meant to read it" do
      account = account_fixture()
      {:ok, keypair} = Accounts.create_keypair(account)

      %{rows: [[stored]]} =
        Repo.query!("SELECT public_key FROM keypairs WHERE account_id = $1", [account.id])

      assert stored == keypair.public_key
    end

    test "only one is live per account at a time" do
      account = account_fixture()
      {:ok, _first} = Accounts.create_keypair(account)

      assert {:error, changeset} = Accounts.create_keypair(account)
      assert errors_on(changeset).account_id != []
    end

    test "a revoked key frees the account for a new one" do
      account = account_fixture()
      {:ok, first} = Accounts.create_keypair(account)
      {:ok, _revoked} = Accounts.revoke_keypair(first)

      assert {:ok, second} = Accounts.create_keypair(account)
      assert Accounts.active_keypair(account).id == second.id
    end

    test "an expired key is not offered for signing" do
      account = account_fixture()
      {:ok, keypair} = Accounts.create_keypair(account)

      Repo.update!(Keypair.expiry_changeset(keypair, DateTime.add(DateTime.utc_now(), -1)))

      assert Accounts.active_keypair(account) == nil
    end

    test "an expired key can still be rotated away from" do
      # The partial unique index cannot know about expiry, since its predicate
      # has to be immutable. Without rotation the account would be stuck:
      # unable to sign, and unable to be given a replacement.
      account = account_fixture()
      {:ok, expired} = Accounts.create_keypair(account)

      Repo.update!(Keypair.expiry_changeset(expired, DateTime.add(DateTime.utc_now(), -1)))

      assert {:error, _} = Accounts.create_keypair(account)
      assert {:ok, fresh} = Accounts.rotate_keypair(account)
      assert Accounts.active_keypair(account).id == fresh.id
      refute fresh.id == expired.id
    end

    test "rotation keeps the old public half readable" do
      # Activities already delivered to other servers are verified against the
      # key that signed them, which may be one we have since replaced.
      account = account_fixture()
      {:ok, old} = Accounts.create_keypair(account)
      {:ok, _new} = Accounts.rotate_keypair(account)

      reloaded = Repo.get!(Keypair, old.id)

      assert reloaded.public_key == old.public_key
      refute is_nil(reloaded.revoked_at)
    end

    test "revoking cannot hand the key to another account" do
      # A live private key moved to a different actor is that actor's identity
      # stolen, so the revoke path does not cast account_id at all.
      account = account_fixture()
      other = account_fixture()
      {:ok, keypair} = Accounts.create_keypair(account)

      {:ok, revoked} = Repo.update(Keypair.revoke_changeset(keypair))

      assert revoked.account_id == account.id
      refute revoked.account_id == other.id
    end

    test "a key that failed to decrypt is not treated as usable" do
      # Cloak's AES.GCM reports a wrong key as the bare atom :error rather than
      # failing, so this really is a shape the struct can hold.
      garbled = %Keypair{account_id: 1, public_key: "pem", private_key: :error}

      refute Keypair.active?(garbled)
      assert Keypair.undecryptable?(garbled)
      refute Keypair.undecryptable?(%Keypair{private_key: "-----BEGIN RSA PRIVATE KEY-----"})
      refute Keypair.undecryptable?(%Keypair{private_key: nil})
    end

    test "accepts the second algorithm the type exists for" do
      account = account_fixture()

      assert {:ok, keypair} =
               %Keypair{}
               |> Keypair.changeset(%{
                 account_id: account.id,
                 type: :ed25519,
                 public_key: "-----BEGIN PUBLIC KEY-----"
               })
               |> Repo.insert()

      assert Repo.get!(Keypair, keypair.id).type == :ed25519
    end

    test "refuses an algorithm that does not exist" do
      account = account_fixture()

      changeset =
        Keypair.changeset(%Keypair{}, %{
          account_id: account.id,
          type: :rot13,
          public_key: "key"
        })

      refute changeset.valid?
    end

    test "are removed with their account" do
      account = account_fixture()
      {:ok, _} = Accounts.create_keypair(account)

      Repo.delete!(account)

      assert Accounts.active_keypair(account.id) == nil
    end
  end
end

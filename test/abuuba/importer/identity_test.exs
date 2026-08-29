defmodule Abuuba.Importer.IdentityTest do
  use Abuuba.DataCase, async: false

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.Keypair
  alias Abuuba.Accounts.User
  alias Abuuba.Federation.URIs
  alias Abuuba.Importer.Identity
  alias Abuuba.MastodonSource, as: Source
  alias Abuuba.OAuth.AccessToken
  alias Abuuba.OAuth.Application, as: OAuthApplication
  alias Abuuba.OAuth.AuthorizationCode
  alias Abuuba.Repo
  alias Abuuba.Roles.Role
  alias Abuuba.WebPush.Subscription

  # The source is Mastodon-shaped tables in the test database, so every query
  # the importer runs is the query it would run against a real one. The
  # encrypted values in them came out of Active Record itself.
  @fixtures "test/support/data/rails_encrypted.json" |> File.read!() |> Jason.decode!()

  @primary "test_primary_key_0123456789abcdef"
  @salt "test_key_derivation_salt_00000000"

  # A bcrypt digest Devise would have written. Copied across untouched, which
  # is the whole point: everybody's password still works.
  @password "correct horse battery staple"
  @digest Bcrypt.hash_pwd_salt(@password)

  setup do
    Source.create!()
    seed!()

    on_exit(&Source.drop!/0)

    :ok
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        repo: Repo,
        prefix: Source.prefix(),
        local_domain: URIs.local_domain(),
        secrets: %{
          "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => @primary,
          "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => @salt
        }
      ],
      extra
    )
  end

  describe "accounts" do
    test "keep their ids, because every id ever published is one of them" do
      :ok = Identity.run(opts())

      assert %Account{username: "alice", domain: nil} = Repo.get(Account, 1)
      assert %Account{username: "carol", domain: "other.example"} = Repo.get(Account, 3)
    end

    test "keep the URLs other servers hold" do
      :ok = Identity.run(opts())

      account = Repo.get(Account, 3)

      assert account.uri == "https://other.example/users/carol"
      assert account.inbox_url == "https://other.example/users/carol/inbox"
      assert account.shared_inbox_url == "https://other.example/inbox"
      assert account.followers_url == "https://other.example/users/carol/followers"
    end

    test "keep the moderation state, not only the profile" do
      :ok = Identity.run(opts())

      assert %Account{suspended_at: %DateTime{}} = Repo.get(Account, 4)
      assert %Account{silenced_at: %DateTime{}} = Repo.get(Account, 5)
    end

    test "keep which URI shape their actor id uses" do
      # An account whose actor id is the numeric form must keep answering on
      # it. Rewriting it to the username form breaks every link to it that
      # exists.
      :ok = Identity.run(opts())

      assert Repo.get(Account, 1).id_scheme == :username
      assert Repo.get(Account, 2).id_scheme == :numeric
    end

    test "keep a move, so followers still get forwarded" do
      :ok = Identity.run(opts())

      moved = Repo.get(Account, 5)

      assert moved.moved_to_account_id == 1
      assert moved.also_known_as == ["https://other.example/users/carol"]
      refute is_nil(moved.moved_at)
    end

    test "a move to an account created later is still a move" do
      # Accounts arrive in id order, so the target of a move can be a row that
      # does not exist yet. Writing the reference in the same pass made the
      # whole batch fail on a foreign key.
      :ok = Identity.run(opts())

      assert Repo.get(Account, 7).moved_to_account_id == 8
    end

    test "carry the actor type, and the bot flag that follows from it" do
      :ok = Identity.run(opts())

      assert %Account{actor_type: :service, bot: true} = Repo.get(Account, 6)
      assert %Account{actor_type: :person, bot: false} = Repo.get(Account, 1)
    end

    test "carry profile fields with their verification intact" do
      :ok = Identity.run(opts())

      assert [%{name: "Website", value: "https://alice.example"} = field] =
               Repo.get(Account, 1).fields

      refute is_nil(field.verified_at)
    end

    test "run twice without writing anything twice" do
      # A takeover is interrupted and restarted. That is normal, and it must
      # not double every row up to the point of the interruption.
      :ok = Identity.run(opts())
      :ok = Identity.run(opts())

      assert Repo.aggregate(Account, :count) == 8
    end
  end

  describe "users" do
    test "keep the password digest, so nobody has to reset anything" do
      :ok = Identity.run(opts())

      user = Repo.get_by(User, account_id: 1)

      assert User.valid_password?(user, @password)
    end

    test "keep confirmation and approval, which are the gates on signing in" do
      :ok = Identity.run(opts())

      assert %User{confirmed_at: %DateTime{}, approved: true} = Repo.get_by(User, account_id: 1)
      assert %User{confirmed_at: nil, approved: false} = Repo.get_by(User, account_id: 2)
    end

    test "keep a disabled account shut" do
      # The one place where dropping a column would silently hand somebody
      # back an account a moderator had taken away.
      :ok = Identity.run(opts())

      user = Repo.get_by(User, account_id: 6)

      assert User.disabled?(user)
      assert Auth.check_sign_in(user) == {:error, :disabled}
    end

    test "keep the second factor, decrypted from theirs and encrypted with ours" do
      :ok = Identity.run(opts())

      user = Repo.get_by(User, account_id: 1)

      assert user.otp_secret == @fixtures["otp"]
      refute is_nil(user.otp_required_at)
    end

    test "leave the second factor off where it was off" do
      :ok = Identity.run(opts())

      user = Repo.get_by(User, account_id: 2)

      assert is_nil(user.otp_secret)
      assert is_nil(user.otp_required_at)
    end

    test "keep the role, and the role keeps its permissions" do
      :ok = Identity.run(opts())

      role = Repo.get(Role, 100)

      assert role.name == "Moderator"
      assert role.permissions == 0x10
      assert Repo.get_by(User, account_id: 1).role_id == 100
    end

    test "keep the settings a person chose" do
      :ok = Identity.run(opts())

      assert Repo.get_by(User, account_id: 1).settings["default_privacy"] == "unlisted"
    end
  end

  describe "keys" do
    test "the account signs with the key the network already trusts" do
      :ok = Identity.run(opts())

      keypair = active_key(1)

      assert keypair.public_key == @fixtures["public_pem"]
      assert keypair.private_key == @fixtures["private_pem"]
    end

    test "a key that was only ever in the legacy columns comes across too" do
      :ok = Identity.run(opts())

      keypair = active_key(2)

      assert keypair.public_key =~ "BEGIN PUBLIC KEY"
      assert keypair.private_key =~ "BEGIN RSA PRIVATE KEY"
    end

    test "a signature made with an imported key verifies against the published half" do
      # The check the whole import exists for. If this fails, every server on
      # the network rejects everything this one sends.
      :ok = Identity.run(opts())

      assert %{checked: 3, failures: []} = signatures(opts())
    end

    test "a stand-by key is kept, but not as the one in use" do
      # abuuba publishes one key per actor. A second live key would be one
      # nothing on the network can resolve, so it is kept and marked.
      :ok = Identity.run(opts())

      standby = Repo.get_by(Keypair, account_id: 1, public_key: legacy_public_pem())

      refute is_nil(standby.revoked_at)
      assert standby.private_key =~ "BEGIN"
    end

    test "says so when the columns it would decrypt cannot be read at all" do
      # An errored query is not proof that there is nothing encrypted, only
      # that the question could not be asked. Waving that through would let an
      # import copy ciphertext nothing here can read.
      Repo.query!("DROP TABLE mastodon_keypairs")

      assert [%{key: "encryption_keys"}] = Identity.check(opts())
    end

    test "a user whose disabled column the source does not have is still imported" do
      # Older schemas are missing columns this one reads, and `nil` is not
      # `false`: a boolean test that assumed otherwise took the whole import
      # down on the first row.
      Repo.query!("ALTER TABLE mastodon_users DROP COLUMN disabled")

      assert :ok = Identity.run(opts())
      refute User.disabled?(Repo.get_by(User, account_id: 1))
    end

    test "refuses rather than importing a key it could not read" do
      # A private key decrypted with the wrong key is bytes that look like a
      # key and sign nothing. Finding that out on the first delivery, weeks
      # later, is the outcome worth paying a hard failure to avoid.
      wrong = opts(secrets: %{"ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "wrong"})

      assert [%{key: "encryption_keys"}] = Identity.check(wrong)
      assert Identity.check(opts()) == []
    end
  end

  describe "OAuth" do
    test "applications keep the client id every installed app has stored" do
      :ok = Identity.run(opts())

      app = Repo.get(OAuthApplication, 300)

      assert app.name == "Phone client"
      assert app.client_id == "client-uid-300"
      assert app.redirect_uris == "https://app.example/callback"
      assert app.scopes == "read write follow"
      assert app.owner_user_id == 30
    end

    test "the client secret still authenticates, though it is stored hashed here" do
      :ok = Identity.run(opts())

      app = Repo.get(OAuthApplication, 300)

      assert Abuuba.OAuth.valid_client_secret?(app, "client-secret-300")
      refute Abuuba.OAuth.valid_client_secret?(app, "not-it")
    end

    test "tokens keep working, which is what stops every app signing out at once" do
      :ok = Identity.run(opts())

      token = Abuuba.OAuth.get_token("token-400")

      assert token.user_id == 30
      assert token.scopes == "read write"
    end

    test "a revoked token stays revoked" do
      :ok = Identity.run(opts())

      assert is_nil(Abuuba.OAuth.get_token("token-401"))
      assert %AccessToken{revoked_at: %DateTime{}} = Repo.get(AccessToken, 401)
    end

    test "a token that had expired is not brought back to life" do
      # abuuba's tokens do not expire, so copying an expired one would hand
      # somebody a credential the source had already stopped honouring.
      :ok = Identity.run(opts())

      assert is_nil(Repo.get(AccessToken, 402))
    end

    test "a subscription whose token was left behind is left behind too" do
      # The token expired and was not copied. Copying the subscription anyway
      # would point it at a row that is not there, which is a foreign key
      # violation that takes the whole batch down.
      :ok = Identity.run(opts())

      assert is_nil(Repo.get(Subscription, 602))
    end

    test "an authorization code in flight still redeems" do
      :ok = Identity.run(opts())

      assert %AuthorizationCode{application_id: 300, user_id: 30} =
               Repo.get(AuthorizationCode, 500)
    end

    test "push subscriptions come across with their keys and their alerts" do
      :ok = Identity.run(opts())

      subscription = Repo.get(Subscription, 600)

      assert subscription.endpoint == "https://push.example/subscription/600"
      assert subscription.key_p256dh == "p256dh-600"
      assert subscription.account_id == 1
      assert subscription.access_token_id == 400
      assert subscription.alerts["mention"] == true
      assert subscription.policy == "followed"
    end

    test "and remember which encryption the browser subscribed with" do
      # A subscription made before aes128gcm has to keep being pushed to the
      # old way, or the messages arrive as noise.
      :ok = Identity.run(opts())

      assert Repo.get(Subscription, 600).encoding == "aes128gcm"
      assert Repo.get(Subscription, 601).encoding == "aesgcm"
    end
  end

  describe "verification" do
    test "compares the actor URLs this server would publish with the source's" do
      :ok = Identity.run(opts())

      assert %{checked: 3, failures: []} = actors(opts())
    end

    test "says which account differs rather than that one does" do
      :ok = Identity.run(opts())

      Repo.query!(
        "UPDATE mastodon_accounts SET uri = 'https://elsewhere.example/users/alice' WHERE id = 1"
      )

      assert %{failures: [%{id: 1}]} = actors(opts())
    end

    test "checks the webfinger name, which is what a client searches by" do
      # A username copied wrongly is an account nobody can find by searching
      # for it, which is the same as it not being here.
      :ok = Identity.run(opts())

      Repo.update_all(from(a in Account, where: a.id == 1), set: [username: "alicia"])

      assert %{failures: [%{id: 1}]} = actors(opts())
    end

    test "notices an account the import never wrote" do
      :ok = Identity.run(opts())

      Repo.delete_all(from(k in Keypair, where: k.account_id == 6))
      Repo.delete_all(from(u in User, where: u.account_id == 6))
      Repo.delete_all(from(a in Account, where: a.id == 6))

      assert %{failures: [%{id: 6, now: nil}]} = actors(opts())
    end
  end

  ## The source

  defp seed! do
    base = URIs.base_url()

    Repo.query!(
      """
      INSERT INTO mastodon_accounts
        (id, username, domain, actor_type, display_name, note, uri, url, inbox_url,
         shared_inbox_url, outbox_url, followers_url, following_url, suspended_at,
         silenced_at, also_known_as, locked, discoverable, indexable, hide_collections,
         moved_to_account_id, id_scheme, fields, private_key, public_key,
         last_webfingered_at, created_at, updated_at)
      VALUES
        (1, 'alice', NULL, 'Person', 'Alice', '<p>hi</p>', '#{base}/users/alice',
         '#{base}/@alice', '', '', '', '', NULL, NULL, NULL, NULL,
         false, true, true, false, NULL, 0,
         '[{"name":"Website","value":"https://alice.example","verified_at":"2026-01-01T00:00:00.000Z"}]',
         NULL, '', NULL, now(), now()),
        (2, 'bob', NULL, NULL, 'Bob', '', '#{base}/ap/users/2', NULL, '', '', '', '',
         NULL, NULL, NULL, NULL, false, false, false, false, NULL, 1, '[]', $1, $2, NULL,
         now(), now()),
        (3, 'carol', 'other.example', 'Person', 'Carol', '', 'https://other.example/users/carol',
         'https://other.example/@carol', 'https://other.example/users/carol/inbox',
         'https://other.example/inbox', 'https://other.example/users/carol/outbox',
         'https://other.example/users/carol/followers', NULL, NULL, NULL, NULL,
         true, false, false, true, NULL, 0, '[]', NULL, 'remote-public-key', now(), now(), now()),
        (4, 'spammer', 'other.example', 'Person', '', '', 'https://other.example/users/spammer',
         NULL, '', '', '', '', NULL, now(), NULL, NULL, false, false, false, false, NULL, 0,
         '[]', NULL, '', NULL, now(), now()),
        (5, 'loud', 'other.example', 'Person', '', '', 'https://other.example/users/loud',
         NULL, '', '', '', '', NULL, NULL, now(), ARRAY['https://other.example/users/carol'],
         false, false, false, false, 1, 0, '[]', NULL, '', NULL, now(), now()),
        (6, 'newsbot', NULL, 'Service', 'News', '', '#{base}/users/newsbot',
         NULL, '', '', '', '', NULL, NULL, NULL, NULL, false, false, false, false, NULL, 0,
         '[]', $3, $4, NULL, now(), now()),
        (7, 'movedaway', 'other.example', 'Person', '', '', 'https://other.example/users/moved',
         NULL, '', '', '', '', NULL, NULL, NULL, NULL, false, false, false, false, 8, 0,
         '[]', NULL, '', NULL, now(), now()),
        (8, 'arrived', 'other.example', 'Person', '', '', 'https://other.example/users/arrived',
         NULL, '', '', '', '', NULL, NULL, NULL, NULL, false, false, false, false, NULL, 0,
         '[]', NULL, '', NULL, now(), now())
      """,
      [legacy_private_pem(), legacy_public_pem(), legacy_private_pem(), legacy_public_pem()]
    )

    Repo.query!(
      """
      INSERT INTO mastodon_user_roles (id, name, color, position, permissions, highlighted, created_at, updated_at)
      VALUES (100, 'Moderator', '#ff0000', 10, 16, true, now(), now())
      """,
      []
    )

    Repo.query!(
      """
      INSERT INTO mastodon_users
        (id, account_id, email, encrypted_password, confirmed_at, approved, disabled,
         role_id, locale, settings, sign_up_ip, current_sign_in_at, otp_secret,
         otp_required_for_login, created_at, updated_at)
      VALUES
        (30, 1, 'alice@example.com', $1, now(), true, false, 100, 'de',
         '{"default_privacy":"unlisted"}', '198.51.100.7', now(), $2, true, now(), now()),
        (31, 2, 'bob@example.com', $1, NULL, false, false, NULL, NULL, NULL, NULL, NULL,
         NULL, false, now(), now()),
        (32, 6, 'news@example.com', $1, now(), true, true, NULL, NULL, NULL, NULL, NULL,
         NULL, false, now(), now())
      """,
      [@digest, @fixtures["otp_cipher"]]
    )

    Repo.query!(
      """
      INSERT INTO mastodon_keypairs
        (id, account_id, type, public_key, private_key, local_fragment, revoked, created_at, updated_at)
      VALUES
        (201, 1, 0, $1, $2, '#rsa-aaaa', false, now(), now()),
        (202, 1, 0, $3, $2, '#rsa-bbbb', false, now(), now())
      """,
      [@fixtures["public_pem"], @fixtures["private_cipher"], legacy_public_pem()]
    )

    Repo.query!("""
    INSERT INTO mastodon_oauth_applications
      (id, name, uid, secret, redirect_uri, scopes, website, owner_id, owner_type, created_at, updated_at)
    VALUES
      (300, 'Phone client', 'client-uid-300', 'client-secret-300', 'https://app.example/callback',
       'read write follow', 'https://app.example', 30, 'User', now(), now())
    """)

    Repo.query!("""
    INSERT INTO mastodon_oauth_access_tokens
      (id, token, application_id, resource_owner_id, scopes, expires_in, revoked_at, last_used_at, created_at)
    VALUES
      (400, 'token-400', 300, 30, 'read write', NULL, NULL, now(), now()),
      (401, 'token-401', 300, 30, 'read', NULL, now(), NULL, now()),
      (402, 'token-402', 300, 30, 'read', 60, NULL, NULL, now() - interval '1 day'),
      (403, 'token-403', 300, 30, 'read', NULL, NULL, NULL, now())
    """)

    Repo.query!("""
    INSERT INTO mastodon_oauth_access_grants
      (id, token, application_id, resource_owner_id, redirect_uri, scopes, code_challenge,
       code_challenge_method, expires_in, revoked_at, created_at)
    VALUES
      (500, 'grant-500', 300, 30, 'https://app.example/callback', 'read', 'challenge', 'S256',
       600, NULL, now())
    """)

    Repo.query!("""
    INSERT INTO mastodon_web_push_subscriptions
      (id, endpoint, key_p256dh, key_auth, data, access_token_id, user_id, standard, created_at, updated_at)
    VALUES
      (600, 'https://push.example/subscription/600', 'p256dh-600', 'auth-600',
       '{"alerts":{"mention":true,"follow":false},"policy":"followed"}', 400, 30, true, now(), now()),
      (601, 'https://push.example/subscription/601', 'p256dh-601', 'auth-601',
       '{"alerts":{"mention":true}}', 403, 30, false, now(), now()),
      (602, 'https://push.example/subscription/602', 'p256dh-602', 'auth-602',
       '{"alerts":{"mention":true}}', 402, 30, true, now(), now())
    """)
  end

  defp signatures(opts), do: Enum.find(Identity.verify(opts), &(&1.name == "signing keys"))

  defp actors(opts), do: Enum.find(Identity.verify(opts), &(&1.name == "actor URLs"))

  # The key an account signs with: the one that is not revoked and has a
  # private half.
  defp active_key(account_id) do
    Keypair
    |> where([k], k.account_id == ^account_id and is_nil(k.revoked_at))
    |> Repo.one!()
  end

  # A pair generated here rather than in the fixture file, because these two
  # accounts stand for the older instances whose keys never left the accounts
  # table and were never encrypted.
  defp legacy_pair do
    Process.get(:legacy_pair) ||
      (
        pair = Keypair.generate()
        Process.put(:legacy_pair, pair)
        pair
      )
  end

  defp legacy_private_pem, do: legacy_pair().private_key
  defp legacy_public_pem, do: legacy_pair().public_key
end

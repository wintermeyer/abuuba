defmodule Abuuba.WebPushTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Notifications
  alias Abuuba.OAuth
  alias Abuuba.WebPush
  alias Abuuba.WebPush.Encryption
  alias Abuuba.WebPush.Subscription
  alias Abuuba.WebPush.VAPID

  setup do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, token, _raw} = OAuth.issue_token(application, user, ["read", "push"])

    keys = browser_keys()

    %{account: account, token: token, application: application, keys: keys}
  end

  # What a browser's PushManager hands a client: a public key and an auth
  # secret, both base64url.
  defp browser_keys do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "p256dh" => Encryption.url_encode(public),
      "auth" => Encryption.url_encode(:crypto.strong_rand_bytes(16))
    }
  end

  defp subscribe(token, account, keys, alerts \\ %{"mention" => true}, policy \\ nil) do
    attrs = %{
      "endpoint" => "https://push.example/abc",
      "key_p256dh" => keys["p256dh"],
      "key_auth" => keys["auth"],
      "alerts" => alerts
    }

    WebPush.subscribe(
      token,
      account,
      if(policy, do: Map.put(attrs, "policy", policy), else: attrs)
    )
  end

  describe "subscribing" do
    test "records where a device wants to be reached", %{
      token: token,
      account: account,
      keys: keys
    } do
      assert {:ok, subscription} = subscribe(token, account, keys)

      assert subscription.endpoint == "https://push.example/abc"
      assert subscription.encoding == "aes128gcm"
    end

    test "replaces rather than adds, because one token is one device", %{
      token: token,
      account: account,
      keys: keys
    } do
      {:ok, first} = subscribe(token, account, keys)
      {:ok, second} = subscribe(token, account, browser_keys())

      assert first.id == second.id
      refute first.key_p256dh == second.key_p256dh
    end

    test "two devices are two subscriptions", %{
      token: token,
      account: account,
      application: app,
      keys: keys
    } do
      # A person has the same account on a phone and a laptop and expects both
      # to buzz. Keyed on the account, the second would replace the first.
      user = Repo.get_by!(Abuuba.Accounts.User, account_id: account.id)
      {:ok, other_token, _} = OAuth.issue_token(app, user, ["read", "push", "write"])

      {:ok, one} = subscribe(token, account, keys)
      {:ok, two} = subscribe(other_token, account, browser_keys())

      refute one.id == two.id
    end

    test "refuses an endpoint that is not https", %{token: token, account: account, keys: keys} do
      # The endpoint is fetched by this server, so anything else is a way to
      # point it somewhere it should not go.
      attrs = %{
        "endpoint" => "http://push.example/abc",
        "key_p256dh" => keys["p256dh"],
        "key_auth" => keys["auth"]
      }

      assert {:error, changeset} = WebPush.subscribe(token, account, attrs)
      assert %{endpoint: [_]} = errors_on(changeset)
    end
  end

  describe "who wants what" do
    test "only the types a device asked for", %{token: token, account: account, keys: keys} do
      # A device that did not name a type did not ask for it, and guessing
      # "probably yes" is how a phone buzzes at three in the morning.
      {:ok, subscription} = subscribe(token, account, keys, %{"mention" => true})

      assert Subscription.wants?(subscription, "mention")
      refute Subscription.wants?(subscription, "follow")
      refute Subscription.wants?(subscription, "reblog")
    end

    test "a notification finds the devices that want it", %{
      token: token,
      account: account,
      keys: keys
    } do
      {:ok, _} = subscribe(token, account, keys, %{"follow" => true})
      {:ok, notification} = Notifications.notify(account, account_fixture(), "follow")

      assert [_subscription] = WebPush.subscriptions_for(notification)
    end

    test "and skips the ones that do not", %{token: token, account: account, keys: keys} do
      {:ok, _} = subscribe(token, account, keys, %{"mention" => true})
      {:ok, notification} = Notifications.notify(account, account_fixture(), "follow")

      assert WebPush.subscriptions_for(notification) == []
    end
  end

  describe "revoking the token a device subscribed with" do
    setup %{account: account} do
      # A second app on the same account, which is the case that matters: one
      # app losing its access must not take another app's notifications with
      # it.
      user = Repo.get_by!(Abuuba.Accounts.User, account_id: account.id)

      {:ok, other_app, _secret} =
        OAuth.create_application(%{name: "other", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, second, _raw} = OAuth.issue_token(other_app, user, ["read", "push"])

      %{second: second}
    end

    test "stops the pushes it was getting", %{
      token: token,
      account: account,
      keys: keys,
      second: second
    } do
      # `revoke_token/1` said in its own words that it removes these, and did
      # not: the call was a stub left from before web push existed, so a person
      # who took an app's access away went on being told about every mention on
      # the device that app had registered.
      {:ok, _} = subscribe(token, account, keys, %{"follow" => true})

      {:ok, kept} =
        WebPush.subscribe(second, account, %{
          "endpoint" => "https://push.example/second",
          "key_p256dh" => keys["p256dh"],
          "key_auth" => keys["auth"],
          "alerts" => %{"follow" => true}
        })

      {:ok, notification} = Notifications.notify(account, account_fixture(), "follow")
      assert length(WebPush.subscriptions_for(notification)) == 2

      :ok = OAuth.revoke_token(token)

      # The positive half: the device whose token is still good keeps hearing.
      # Without it, an assertion that the list shrank would pass just as well
      # if revoking had emptied the table.
      assert [%{id: id}] = WebPush.subscriptions_for(notification)
      assert id == kept.id
    end

    test "and forgets the subscription rather than leaving it behind", %{
      token: token,
      account: account,
      keys: keys
    } do
      {:ok, subscription} = subscribe(token, account, keys)

      :ok = OAuth.revoke_token(token)

      refute Repo.get(Subscription, subscription.id)
    end

    test "and a revoked token cannot be pushed to even if a row survives", %{
      token: token,
      account: account,
      keys: keys
    } do
      # The backstop. Deleting the row is the fix; this is what happens if some
      # other path ever leaves one behind, because a subscription that outlives
      # its token must fail closed rather than keep delivering.
      {:ok, subscription} = subscribe(token, account, keys, %{"follow" => true})

      Repo.update!(Ecto.Changeset.change(token, revoked_at: DateTime.utc_now()))

      {:ok, notification} = Notifications.notify(account, account_fixture(), "follow")

      assert Repo.get(Subscription, subscription.id)
      assert WebPush.subscriptions_for(notification) == []
    end
  end

  describe "the bulk revocations" do
    test "signing an app out takes its device with it", %{
      account: account,
      keys: keys,
      token: token,
      application: application
    } do
      {:ok, subscription} = subscribe(token, account, keys)
      user = Repo.get_by!(Abuuba.Accounts.User, account_id: account.id)

      :ok = OAuth.revoke_application_for(user, application.id)

      refute Repo.get(Subscription, subscription.id)
    end

    test "and so does a password reset, in the same transaction", %{
      account: account,
      keys: keys,
      token: token
    } do
      # Somebody resetting their password usually thinks another person is in
      # their account. Both apps go, and both devices with them.
      {:ok, one} = subscribe(token, account, keys)

      user = Repo.get_by!(Abuuba.Accounts.User, account_id: account.id)

      {:ok, other_app, _secret} =
        OAuth.create_application(%{name: "other", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, second, _raw} = OAuth.issue_token(other_app, user, ["read", "push"])

      {:ok, two} =
        WebPush.subscribe(second, account, %{
          "endpoint" => "https://push.example/second",
          "key_p256dh" => keys["p256dh"],
          "key_auth" => keys["auth"]
        })

      {:ok, _} =
        Ecto.Multi.new() |> OAuth.revoke_all_multi(user) |> Repo.transaction()

      refute Repo.get(Subscription, one.id)
      refute Repo.get(Subscription, two.id)
    end

    test "and somebody else's devices are untouched", %{account: account, keys: keys} do
      # The positive control. A delete that took the whole table would pass
      # every assertion above it.
      stranger = account_fixture()

      stranger_user =
        user_fixture(%{
          account_id: stranger.id,
          approved: true,
          confirmed_at: DateTime.utc_now()
        })

      {:ok, app, _secret} =
        OAuth.create_application(%{name: "theirs", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

      {:ok, their_token, _raw} = OAuth.issue_token(app, stranger_user, ["read", "push"])

      {:ok, theirs} =
        WebPush.subscribe(their_token, stranger, %{
          "endpoint" => "https://push.example/theirs",
          "key_p256dh" => keys["p256dh"],
          "key_auth" => keys["auth"]
        })

      user = Repo.get_by!(Abuuba.Accounts.User, account_id: account.id)

      {:ok, _} = Ecto.Multi.new() |> OAuth.revoke_all_multi(user) |> Repo.transaction()

      assert Repo.get(Subscription, theirs.id)
    end
  end

  describe "the policy on a subscription" do
    test "none means nobody, which is what somebody asking for it meant", %{
      token: token,
      account: account,
      keys: keys
    } do
      # The field was stored and validated and read nowhere, so every
      # subscription behaved as `all` -- somebody who asked for no pushes got
      # all of them.
      {:ok, _} = subscribe(token, account, keys, %{"follow" => true}, "none")
      {:ok, notification} = Notifications.notify(account, account_fixture(), "follow")

      assert WebPush.subscriptions_for(notification) == []
    end

    test "followed means only somebody you follow", %{
      token: token,
      account: account,
      keys: keys
    } do
      stranger = account_fixture()
      friend = account_fixture()
      {:ok, _follow} = Abuuba.Relationships.follow(account, friend)

      {:ok, _} = subscribe(token, account, keys, %{"follow" => true}, "followed")

      {:ok, from_stranger} = Notifications.notify(account, stranger, "follow")
      assert WebPush.subscriptions_for(from_stranger) == []

      {:ok, from_friend} = Notifications.notify(account, friend, "follow")
      assert [_subscription] = WebPush.subscriptions_for(from_friend)
    end

    test "follower means only somebody who follows you", %{
      token: token,
      account: account,
      keys: keys
    } do
      stranger = account_fixture()
      fan = account_fixture()
      {:ok, _follow} = Abuuba.Relationships.follow(fan, account)

      {:ok, _} = subscribe(token, account, keys, %{"favourite" => true}, "follower")

      {:ok, from_stranger} = Notifications.notify(account, stranger, "favourite")
      assert WebPush.subscriptions_for(from_stranger) == []

      {:ok, from_fan} = Notifications.notify(account, fan, "favourite")
      assert [_subscription] = WebPush.subscriptions_for(from_fan)
    end

    test "and a subscription without one still hears from anybody", %{
      token: token,
      account: account,
      keys: keys
    } do
      # The control. A policy nobody set must not start filtering, or every
      # existing device goes quiet on the day this ships.
      {:ok, _} = subscribe(token, account, keys, %{"follow" => true})
      {:ok, notification} = Notifications.notify(account, account_fixture(), "follow")

      assert [_subscription] = WebPush.subscriptions_for(notification)
    end
  end

  describe "the payload" do
    setup %{token: token, account: account, keys: keys} do
      {:ok, subscription} = subscribe(token, account, keys)

      %{subscription: subscription}
    end

    test "says who and what, and little else", %{
      account: account,
      subscription: subscription
    } do
      sender = account_fixture(%{display_name: "Bob"})
      status = status_fixture(%{account_id: sender.id, text: "hello there"})
      {:ok, notification} = Notifications.notify(account, sender, "mention", status_id: status.id)

      payload = WebPush.payload(notification, subscription, "token")

      assert payload["title"] == "Bob mentioned you"
      assert payload["body"] == "hello there"
      assert payload["notification_type"] == "mention"
      assert payload["notification_id"] == to_string(notification.id)
    end

    test "cuts the body, because a notification is a nudge and not the post", %{
      account: account,
      subscription: subscription
    } do
      sender = account_fixture()
      status = status_fixture(%{account_id: sender.id, text: String.duplicate("a", 400)})
      {:ok, notification} = Notifications.notify(account, sender, "mention", status_id: status.id)

      payload = WebPush.payload(notification, subscription, "token")

      assert String.length(payload["body"]) == WebPush.body_limit()
    end

    test "falls back to a username where somebody set no display name", %{
      account: account,
      subscription: subscription
    } do
      sender = account_fixture(%{username: "carol"})
      {:ok, notification} = Notifications.notify(account, sender, "follow")

      assert WebPush.payload(notification, subscription, "t")["title"] == "carol followed you"
    end
  end

  describe "encryption" do
    test "seals a payload the standard way", %{keys: keys} do
      assert {:ok, %{body: body, headers: headers}} =
               Encryption.encrypt("hello", keys["p256dh"], keys["auth"], "aes128gcm")

      assert {"content-encoding", "aes128gcm"} in headers
      # Header is salt(16) + record size(4) + key length(1) + key(65), then the
      # ciphertext and its tag.
      assert byte_size(body) > 86
    end

    test "seals one the legacy way, for subscriptions made before the standard", %{keys: keys} do
      # A browser does not re-subscribe because a standard was finished; the
      # old ones keep working until it renews them on its own.
      assert {:ok, %{headers: headers}} =
               Encryption.encrypt("hello", keys["p256dh"], keys["auth"], "aesgcm")

      assert {"content-encoding", "aesgcm"} in headers
      assert Enum.any?(headers, &match?({"encryption", "salt=" <> _}, &1))
      assert Enum.any?(headers, &match?({"crypto-key", "dh=" <> _}, &1))
    end

    test "produces a different ciphertext every time", %{keys: keys} do
      # A fresh keypair and salt per message, so two identical notifications do
      # not produce identical bytes on the wire.
      {:ok, one} = Encryption.encrypt("hello", keys["p256dh"], keys["auth"])
      {:ok, two} = Encryption.encrypt("hello", keys["p256dh"], keys["auth"])

      refute one.body == two.body
    end

    test "refuses a key that is not one", %{keys: keys} do
      assert Encryption.encrypt("hello", "not base64!!", keys["auth"]) == {:error, :invalid_key}
      assert Encryption.encrypt("hello", keys["p256dh"], nil) == {:error, :invalid_key}
    end

    test "decodes base64url with or without padding" do
      assert {:ok, "hi"} = Encryption.decode(Base.url_encode64("hi", padding: false))
      assert {:ok, "hi"} = Encryption.decode(Base.url_encode64("hi"))
    end
  end

  describe "VAPID" do
    test "says plainly when this server cannot push" do
      # Better than accepting subscriptions that will never be delivered to.
      Application.put_env(:abuuba, :web_push, [])

      refute VAPID.configured?()
      assert VAPID.authorization("https://push.example/abc") == {:error, :not_configured}
    end

    test "signs an assertion naming the push service" do
      keypair = VAPID.generate_keypair()

      Application.put_env(:abuuba, :web_push,
        public_key: keypair.public_key,
        private_key: keypair.private_key,
        subject: "mailto:admin@abuuba.test"
      )

      on_exit(fn -> Application.put_env(:abuuba, :web_push, []) end)

      assert {:ok, "vapid t=" <> rest} = VAPID.authorization("https://push.example/abc")
      assert [token, key] = String.split(rest, ", k=")

      # Three parts, and the middle one names the service's own origin rather
      # than the endpoint, which is what the services check.
      assert [_header, claims, _signature] = String.split(token, ".")
      assert {:ok, decoded} = Encryption.decode(claims)
      assert Jason.decode!(decoded)["aud"] == "https://push.example"
      assert key == keypair.public_key
    end

    test "a generated keypair is usable for encryption too" do
      keypair = VAPID.generate_keypair()

      assert {:ok, _} = Encryption.decode(keypair.public_key)
      assert {:ok, _} = Encryption.decode(keypair.private_key)
    end
  end
end

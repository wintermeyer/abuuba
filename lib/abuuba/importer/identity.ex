defmodule Abuuba.Importer.Identity do
  @moduledoc """
  The half of a takeover that has to be exact: who everybody is.

  Posts can be re-fetched and media can be downloaded again. An identity
  cannot. If an account's id changes, every link to it on the network is a
  404; if its signing key changes, every server rejects everything it sends;
  if a password digest is not carried across, everybody is locked out on the
  morning of the migration and the migration is what they blame.

  So this step copies rather than translates wherever it can. Ids stay the
  same, because the source's ids are already snowflakes and every URL ever
  published contains one. Bcrypt digests stay the same, because both servers
  check passwords the same way. OAuth client ids stay the same, because they
  are stored inside apps on other people's phones.

  ## Two things are read rather than copied

  Private keys and two-factor secrets sit in columns Rails encrypted. They are
  decrypted with the source's own keys and encrypted again with ours, and the
  import stops before writing anything if those keys turn out not to work.
  Copying the ciphertext instead would finish, look fine, and leave every
  account unable to sign.

  ## One key per account

  Mastodon can hold several keys for an actor and publishes whichever it signs
  with. abuuba publishes one. The one taken is the one the source was signing
  with, so the public half other servers fetch after the switch is the half
  they were already trusting. Any others are kept, so nothing is lost, but
  marked as not in use: a live key nothing on the network can resolve is worse
  than a row that says so.

  ## What is deliberately left behind

  Sessions, confirmation and reset tokens, sign-in counts and address history.
  Everybody signs in again after a takeover, and a copied session is a copied
  cookie.
  """

  @behaviour Abuuba.Importer.Step

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Keypair
  alias Abuuba.Accounts.User
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs
  alias Abuuba.Importer.Batch
  alias Abuuba.Importer.Rails.Encryption
  alias Abuuba.Importer.Source
  alias Abuuba.OAuth
  alias Abuuba.OAuth.AccessToken
  alias Abuuba.OAuth.Application, as: OAuthApplication
  alias Abuuba.OAuth.AuthorizationCode
  alias Abuuba.Repo
  alias Abuuba.Roles.Role
  alias Abuuba.WebPush.Subscription
  alias Abuuba.WebPush.VAPID

  @doc """
  Copies roles, accounts, keys, users and OAuth credentials.

  `:ok`, or `{:error, {what, reason}}` naming the part that stopped.
  """
  @impl Abuuba.Importer.Step
  @spec run(keyword()) :: :ok | {:error, {atom(), term()}}
  def run(opts), do: opts |> with_keys() |> Batch.run_parts(parts())

  # Roles before users, because a user row names one; accounts before both,
  # because everything else hangs off an account.
  defp parts do
    [
      {:roles, &copy_roles/2},
      {:accounts, &copy_accounts/2},
      {:moves, &copy_moves/2},
      {:keypairs, &copy_keypairs/2},
      {:users, &copy_users/2},
      {:oauth_applications, &copy_applications/2},
      {:oauth_access_tokens, &copy_tokens/2},
      {:oauth_authorization_codes, &copy_grants/2},
      {:push_subscriptions, &copy_subscriptions/2}
    ]
  end

  @doc """
  Whether the keys in the environment actually read this data.

  A precondition rather than a step of its own, so that the dry run reports it.
  Copying ciphertext with the wrong key would finish, look fine, and leave
  every account unable to sign; finding that out after `--execute` is finding
  it out too late.
  """
  @impl Abuuba.Importer.Step
  @spec check(keyword()) :: [Abuuba.Importer.Step.problem()]
  def check(opts) do
    case opts |> with_keys() |> readable?() do
      :ok ->
        []

      {:error, reason} ->
        [
          %{
            key: "encryption_keys",
            detail: detail(reason)
          }
        ]
    end
  end

  @doc """
  Proves the import, after it has run.

  Two questions, and neither is answerable without the source still being
  there: does a signature made with an imported key verify against the public
  half the old server published, and would this server publish the same actor
  URL and webfinger name that one did?

  A takeover that answers no to either has already broken. Asking here is how
  that is found out during the maintenance window rather than from the first
  delivery that bounces.
  """
  @impl Abuuba.Importer.Step
  @spec verify(keyword()) :: [Abuuba.Importer.Step.verification()]
  def verify(opts) do
    opts = with_keys(opts)

    [check_signatures(opts), check_actors(opts)]
  end

  ## Before anything is written

  # One encrypted value, decrypted, before a single row moves. The alternative
  # is finding out halfway through that the keys in the environment are not the
  # keys this data was written with.
  defp readable?(opts) do
    sql = """
    SELECT private_key AS value FROM #{table(opts, "keypairs")} WHERE private_key IS NOT NULL
    UNION ALL
    SELECT otp_secret AS value FROM #{table(opts, "users")} WHERE otp_secret IS NOT NULL
    LIMIT 1
    """

    case rows(opts, sql) do
      {:ok, [%{"value" => value} | _rest]} -> decryptable?(value, opts)
      {:ok, []} -> :ok
      # Not proof that there is nothing encrypted, only that the question could
      # not be asked. A check whose dependency failed has to say so: silence
      # here would wave through exactly the import it exists to stop.
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp decryptable?(value, opts) do
    case Encryption.decrypt(value, keys(opts)) do
      {:ok, _plain} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Derived once for the whole import and carried in the options. Deriving them
  # is 65,536 rounds of PBKDF2 against inputs that never change, so doing it per
  # row would spend hours recomputing the same thirty-two bytes.
  defp with_keys(opts) do
    secrets = Keyword.get(opts, :secrets, %{})

    Keyword.put_new_lazy(opts, :encryption_keys, fn ->
      Encryption.keys(
        Map.get(secrets, "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY", ""),
        Map.get(secrets, "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT", "")
      )
    end)
  end

  defp keys(opts), do: Keyword.fetch!(opts, :encryption_keys)

  defp detail(:unreadable) do
    "the source's keypairs and users tables could not be read; this code needs both to know whether it can decrypt what it is copying"
  end

  defp detail(reason) do
    "an encrypted column in the source did not decrypt (#{reason}); check MASTODON_ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY and MASTODON_ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT against the old server's environment"
  end

  ## Roles

  # The permission bits are the same numbers on both sides: they are part of
  # the admin API rather than something either project chose.
  defp copy_roles(opts, name) do
    copy(opts, name, Role, "SELECT * FROM #{table(opts, "user_roles")}", fn row ->
      %{
        id: row["id"],
        name: row["name"] || "",
        color: row["color"] || "",
        position: row["position"] || 0,
        permissions: row["permissions"] || 0,
        highlighted: row["highlighted"] || false,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  ## Accounts

  defp copy_accounts(opts, name) do
    copy(opts, name, Account, "SELECT * FROM #{table(opts, "accounts")}", fn row ->
      type = Account.actor_type(row["actor_type"])

      %{
        id: row["id"],
        username: row["username"],
        domain: presence(row["domain"]),
        actor_type: type,
        # Derived rather than copied: the source has no such column, it asks
        # the actor type the same question every time it needs an answer.
        bot: Account.bot?(type),
        display_name: row["display_name"] || "",
        note: row["note"] || "",
        uri: presence(row["uri"]),
        url: presence(row["url"]),
        inbox_url: presence(row["inbox_url"]),
        shared_inbox_url: presence(row["shared_inbox_url"]),
        outbox_url: presence(row["outbox_url"]),
        followers_url: presence(row["followers_url"]),
        following_url: presence(row["following_url"]),
        suspended_at: at(row["suspended_at"]),
        silenced_at: at(row["silenced_at"]),
        sensitized_at: at(row["sensitized_at"]),
        also_known_as: row["also_known_as"] || [],
        locked: row["locked"] || false,
        discoverable: row["discoverable"] || false,
        indexable: row["indexable"] || false,
        hide_collections: row["hide_collections"] || false,
        # The reference itself is written afterwards, by the `moves` part:
        # accounts arrive in id order and the target of a move can be a row
        # that does not exist yet, which is a foreign key violation that takes
        # the whole batch with it.
        #
        # The source records the target but not when. Without a time the
        # account reads as never having moved, so the row's own last change
        # stands in for it.
        moved_at: if(row["moved_to_account_id"], do: at(row["updated_at"])),
        id_scheme: id_scheme(row["id_scheme"]),
        fields: fields(row["fields"]),
        last_fetched_at: at(row["last_webfingered_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # Which URI shape this account's actor id uses. An account that answers on
  # the numeric form has to keep answering on it, so this is copied rather
  # than decided.
  defp id_scheme(1), do: :numeric
  defp id_scheme(_username), do: :username

  defp fields(fields) when is_list(fields) do
    Enum.map(fields, fn field ->
      %Account.Field{
        name: field["name"] || "",
        value: field["value"] || "",
        verified_at: at(field["verified_at"])
      }
    end)
  end

  defp fields(_not_a_list), do: []

  # Once every account is in, so that a move to an account created later than
  # the one that moved has something to point at. Rare enough that one
  # statement per row costs nothing, and rows the source points at but this
  # import did not write are left alone rather than failing.
  defp copy_moves(opts, name) do
    sql = """
    SELECT id, moved_to_account_id FROM #{table(opts, "accounts")}
    WHERE moved_to_account_id IS NOT NULL
    """

    page(opts, name, Account, sql, fn moved ->
      Enum.each(moved, fn row ->
        Account
        |> where([a], a.id == ^row["id"])
        |> Repo.update_all(set: [moved_to_account_id: row["moved_to_account_id"]])
      end)

      {:ok, []}
    end)
  end

  ## Keys

  # Paged over accounts rather than over the source's keypairs table, because
  # the question being answered is "which key does this account sign with",
  # and for older accounts the answer is not in that table at all.
  defp copy_keypairs(opts, name) do
    page(opts, name, Keypair, "SELECT * FROM #{table(opts, "accounts")}", fn accounts ->
      # Only local ones: a remote account's key is the one its actor document
      # published, and asking the source's keypairs table about a batch that is
      # entirely remote is a round trip for nothing. On a real instance remote
      # accounts outnumber local ones by orders of magnitude.
      local = Enum.reject(accounts, &is_binary(&1["domain"]))
      keys = source_keys(opts, Enum.map(local, & &1["id"]))
      now = DateTime.utc_now()

      accounts
      |> Enum.flat_map(&keypair_rows(&1, Map.get(keys, &1["id"], []), now, opts))
      |> Batch.first_error()
    end)
  end

  defp source_keys(_opts, []), do: %{}

  defp source_keys(opts, ids) do
    sql = "SELECT * FROM #{table(opts, "keypairs")} WHERE account_id = ANY($1) ORDER BY id ASC"

    case rows(opts, sql, [ids]) do
      {:ok, rows} -> Enum.group_by(rows, & &1["account_id"])
      _error -> %{}
    end
  end

  # A remote actor's key is the one its actor document published, which is the
  # legacy column. Its other keys are public halves that can be fetched again,
  # and copying them would leave this server with two answers to "which key
  # does that actor sign with".
  defp keypair_rows(%{"domain" => domain} = account, _keys, _now, opts) when is_binary(domain) do
    case legacy_key(account) do
      nil -> []
      key -> [row_for(account, key, nil, opts)]
    end
  end

  # A local one signs with the oldest key it can still use, because rotation
  # adds stand-by keys with higher ids before retiring the lower ones. Older
  # instances have no rows at all and sign with the legacy columns.
  defp keypair_rows(account, keys, now, opts) do
    active = published_key(account, keys, now)

    if active do
      # By id, which the legacy columns do not have, so a legacy active key
      # leaves every row in the source's table to be marked instead.
      inactive = Enum.reject(keys, &(&1["id"] == active["id"]))

      [row_for(account, active, nil, opts) | Enum.map(inactive, &row_for(account, &1, now, opts))]
    else
      []
    end
  end

  # The key the source publishes for an account, and therefore the one the rest
  # of the network has cached: the oldest it can still use, because rotation
  # adds stand-by keys with higher ids before retiring the lower ones. Older
  # instances have no rows at all and sign with the legacy columns.
  #
  # One definition, read by both the import and the verification. Two would
  # agree with each other right up until they did not, and then the check would
  # certify the wrong key.
  defp published_key(account, keys, now) do
    keys |> Enum.filter(&usable?(&1, now)) |> List.first() || legacy_key(account)
  end

  defp usable?(key, now) do
    not key["revoked"] and
      (is_nil(key["expires_at"]) or DateTime.compare(at(key["expires_at"]), now) == :gt)
  end

  # The two columns an older instance keeps its key in, shaped like a row from
  # the keypairs table so that nothing downstream has to know which of the two
  # it came from. Never encrypted: that column predates Active Record
  # Encryption.
  defp legacy_key(account) do
    case presence(account["public_key"]) do
      nil ->
        nil

      public ->
        %{
          "public_key" => public,
          "private_key" => presence(account["private_key"]),
          "type" => 0,
          "revoked" => false,
          "created_at" => account["created_at"],
          "updated_at" => account["updated_at"]
        }
    end
  end

  defp row_for(account, key, revoked_at, opts) do
    case private_key(key, opts) do
      {:error, reason} ->
        {:error, {reason, account["id"]}}

      private ->
        %{
          account_id: account["id"],
          type: key_type(key["type"]),
          public_key: key["public_key"],
          private_key: private,
          # A stand-by key is not revoked on the source. It is marked here
          # because abuuba publishes one key per actor, and an unmarked second
          # one would take the place of the one the network trusts.
          revoked_at: revoked_at || revoked_at_of(key),
          expires_at: at(key["expires_at"]),
          inserted_at: at(key["created_at"]) || DateTime.utc_now(),
          updated_at: at(key["updated_at"]) || DateTime.utc_now()
        }
    end
  end

  defp revoked_at_of(%{"revoked" => true} = key), do: at(key["updated_at"]) || DateTime.utc_now()
  defp revoked_at_of(_live), do: nil

  # Told apart by looking at the value rather than by remembering where it came
  # from: the legacy column is a bare PEM and the newer table holds an
  # envelope, and nothing else can be mistaken for one.
  defp private_key(key, opts), do: decrypted(key["private_key"], opts)

  defp key_type(1), do: :ed25519
  defp key_type(_rsa), do: :rsa_2048

  ## Users

  defp copy_users(opts, name) do
    copy(opts, name, User, "SELECT * FROM #{table(opts, "users")}", fn row ->
      case otp_secret(row, opts) do
        {:error, reason} -> {:error, {reason, row["id"]}}
        secret -> user_row(row, secret)
      end
    end)
  end

  defp user_row(row, otp_secret) do
    %{
      id: row["id"],
      account_id: row["account_id"],
      email: row["email"],
      hashed_password: presence(row["encrypted_password"]),
      confirmed_at: at(row["confirmed_at"]),
      confirmation_sent_at: at(row["confirmation_sent_at"]),
      # Disabling is not a column of its own on either side: it is "approved
      # once, not approved now", which is what the admin area and the admin
      # API already read. Dropping it would hand a disabled account back on
      # the day of the takeover.
      approved: row["disabled"] != true and row["approved"] == true,
      approved_at: approved_at(row),
      role_id: row["role_id"],
      invite_id: row["invite_id"],
      locale: presence(row["locale"]),
      settings: settings(row["settings"]),
      sign_up_ip: address(row["sign_up_ip"]),
      last_signed_in_at: at(row["current_sign_in_at"]),
      otp_secret: otp_secret,
      otp_required_at: if(row["otp_required_for_login"], do: at(row["updated_at"])),
      inserted_at: at(row["created_at"]),
      updated_at: at(row["updated_at"])
    }
  end

  # Only ever set where somebody was let in at some point, because that is
  # what tells a disabled account apart from a registration nobody has looked
  # at yet. The source does not record when, so the row's own last change
  # stands in for it.
  defp approved_at(row) do
    if row["approved"] || row["disabled"], do: at(row["updated_at"])
  end

  defp otp_secret(row, opts), do: decrypted(row["otp_secret"], opts)

  # `nil`, the plaintext, or an error. Values Rails never encrypted come back
  # as they are: the legacy key column predates Active Record Encryption, and
  # an instance that has never had a two-factor secret has never written one.
  defp decrypted(value, opts) do
    cond do
      presence(value) == nil -> nil
      not Encryption.encrypted?(value) -> value
      true -> unwrap(Encryption.decrypt(value, keys(opts)))
    end
  end

  defp unwrap({:ok, plain}), do: plain
  defp unwrap({:error, reason}), do: {:error, reason}

  # Stored as a JSON string on the source. Anything that will not parse falls
  # back to the defaults rather than taking the import down with it: a lost
  # preference is a preference somebody sets again.
  defp settings(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _not_json -> %{}
    end
  end

  defp settings(_missing), do: %{}

  defp address(%Postgrex.INET{address: address}), do: address |> :inet.ntoa() |> to_string()
  defp address(_none), do: nil

  ## OAuth

  defp copy_applications(opts, name) do
    sql = "SELECT * FROM #{table(opts, "oauth_applications")}"
    # One lookup for the import rather than one per row: every application gets
    # this server's key, because it is the server's and not the app's.
    vapid_key = VAPID.public_key()

    copy(opts, name, OAuthApplication, sql, fn row ->
      %{
        id: row["id"],
        name: row["name"],
        website: presence(row["website"]),
        # The id an installed app has stored. Reissuing it would sign every
        # user of that app out, on every device, at once.
        client_id: row["uid"],
        hashed_client_secret: OAuth.hash(row["secret"]),
        redirect_uris: row["redirect_uri"] || "",
        scopes: presence(row["scopes"]) || "read",
        vapid_key: vapid_key,
        owner_user_id: owner_user_id(row),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # The source's owner is polymorphic and can name something other than a
  # user. Anything else is nobody, as far as this column is concerned.
  defp owner_user_id(%{"owner_type" => "User", "owner_id" => id}), do: id
  defp owner_user_id(_other), do: nil

  defp copy_tokens(opts, name) do
    # An expired token is left behind. abuuba's tokens do not expire, so copying
    # one would hand back a credential the source had already stopped
    # honouring.
    sql = """
    SELECT * FROM #{table(opts, "oauth_access_tokens")} t
    WHERE #{unexpired("t")}
    """

    copy(opts, name, AccessToken, sql, fn row ->
      %{
        id: row["id"],
        hashed_token: OAuth.hash(row["token"]),
        scopes: presence(row["scopes"]) || "read",
        revoked_at: at(row["revoked_at"]),
        last_used_at: at(row["last_used_at"]),
        application_id: row["application_id"],
        user_id: row["resource_owner_id"],
        inserted_at: at(row["created_at"])
      }
    end)
  end

  defp copy_grants(opts, name) do
    # Ten minutes of life, on both sides. The dead ones are not worth the rows;
    # the ones in flight are somebody halfway through signing in to an app
    # while the switch happens.
    sql = """
    SELECT * FROM #{table(opts, "oauth_access_grants")}
    WHERE created_at + (expires_in * interval '1 second') > now()
    """

    copy(opts, name, AuthorizationCode, sql, fn row ->
      %{
        id: row["id"],
        hashed_code: OAuth.hash(row["token"]),
        redirect_uri: row["redirect_uri"],
        scopes: presence(row["scopes"]) || "read",
        code_challenge: presence(row["code_challenge"]),
        code_challenge_method: presence(row["code_challenge_method"]),
        expires_at: DateTime.add(at(row["created_at"]), row["expires_in"] || 0, :second),
        used_at: at(row["revoked_at"]),
        application_id: row["application_id"],
        user_id: row["resource_owner_id"],
        inserted_at: at(row["created_at"])
      }
    end)
  end

  # Joined to users because the source hangs a subscription off the user and
  # abuuba hangs it off the account.
  defp copy_subscriptions(opts, name) do
    # Joined to the tokens as well as to the users, and with the same condition
    # the tokens themselves were copied under: a subscription whose token was
    # left behind would point at a row that is not here, which is a foreign key
    # violation rather than a missing subscription.
    sql = """
    SELECT s.*, u.account_id AS account_id
    FROM #{table(opts, "web_push_subscriptions")} s
    JOIN #{table(opts, "users")} u ON u.id = s.user_id
    JOIN #{table(opts, "oauth_access_tokens")} t ON t.id = s.access_token_id
    WHERE #{unexpired("t")}
    """

    copy(opts, name, Subscription, sql, fn row ->
      data = row["data"] || %{}

      %{
        id: row["id"],
        endpoint: row["endpoint"],
        key_p256dh: row["key_p256dh"],
        key_auth: row["key_auth"],
        alerts: data["alerts"] || %{},
        policy: data["policy"] || "all",
        # Which encryption the browser subscribed with. A subscription made
        # before the standard one has to keep being pushed to the old way, or
        # the messages arrive as noise.
        encoding: if(row["standard"], do: "aes128gcm", else: "aesgcm"),
        access_token_id: row["access_token_id"],
        account_id: row["account_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # One definition, because it is asked twice: once of the tokens themselves and
  # once of the subscriptions that hang off them. Two would drift, and the
  # drift would be a subscription pointing at a token that was not copied.
  defp unexpired(alias_name) do
    "#{alias_name}.expires_in IS NULL OR " <>
      "#{alias_name}.created_at + (#{alias_name}.expires_in * interval '1 second') > now()"
  end

  ## Verification

  # Both checks walk the source's local accounts in pages, the same way the
  # import wrote them. Reading a million-row table into memory to verify it is
  # the kind of thing that turns a maintenance window into an outage.
  defp check_signatures(opts) do
    {checked, failures} =
      scan(opts, fn accounts ->
        ids = Enum.map(accounts, & &1["id"])
        keypairs = active_keypairs(ids)
        published = source_keys(opts, ids)
        now = DateTime.utc_now()

        # What is left is what failed. An account with no key it can sign with
        # is one of them: a local account that cannot sign is an account the
        # rest of the network will stop accepting anything from.
        Enum.reject(accounts, fn account ->
          keypair = Map.get(keypairs, account["id"])
          source = published_key(account, Map.get(published, account["id"], []), now)

          keypair != nil and signs?(account, keypair, source)
        end)
      end)

    %{
      name: "signing keys",
      checked: checked,
      failures: Enum.map(failures, &%{id: &1["id"], username: &1["username"]})
    }
  end

  # Each local account as the source has it, against the same account as this
  # server now holds it. Two things have to agree: the actor URL, which is what
  # every link on the fediverse points at, and the webfinger handle, which is
  # what a client searches by.
  defp check_actors(opts) do
    {checked, failures} =
      scan(opts, fn accounts ->
        imported = imported_accounts(Enum.map(accounts, & &1["id"]))

        Enum.flat_map(accounts, &difference(&1, Map.get(imported, &1["id"])))
      end)

    %{name: "actor URLs", checked: checked, failures: failures}
  end

  # Through `Accounts.active_keypair/1`'s own rule, which is what the delivery
  # worker asks when it actually signs something, but for the whole page in one
  # query rather than one round trip per account.
  defp active_keypairs(ids) do
    Keypair
    |> where([k], k.account_id in ^ids)
    |> where([k], is_nil(k.revoked_at) and not is_nil(k.private_key))
    |> Repo.all()
    |> Enum.filter(&Keypair.active?/1)
    |> Map.new(&{&1.account_id, &1})
  end

  # A real signature over a real request, checked against the public half the
  # old server published, rather than a comparison of two PEM strings. The
  # question is whether other servers will accept what this one sends, and only
  # the whole path answers it.
  defp signs?(account, keypair, published) do
    with pem when is_binary(pem) <- published_pem(account, published),
         {:ok, headers} <-
           Signature.sign(
             method: :get,
             url: URIs.base_url() <> "/.well-known/webfinger",
             key_id: Signature.key_id(account["uri"] || ""),
             private_key: keypair.private_key
           ),
         {:ok, _key_id} <-
           Signature.verify(
             method: :get,
             path: "/.well-known/webfinger",
             headers: headers,
             resolve_key: fn _requested -> {:ok, pem} end
           ) do
      true
    else
      _no -> false
    end
  end

  defp published_pem(_account, %{"public_key" => pem}), do: pem
  defp published_pem(account, _none), do: presence(account["public_key"])

  defp imported_accounts(ids) do
    Account
    |> where([a], a.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp difference(source, nil), do: [%{id: source["id"], was: source["uri"], now: nil}]

  defp difference(source, account) do
    # Asked of the generator rather than worked out again here. The check
    # exists to prove that what this server publishes matches what the old one
    # did, and a second copy of the rule would agree with itself while the
    # server published something else. The stored URI is blanked so that
    # `Actor.id/1` has to derive one instead of handing back what was copied.
    generated = Actor.id(%{account | uri: nil})
    published = presence(source["uri"])
    handle = URIs.full_handle(account)
    subject = "#{source["username"]}@#{URIs.local_domain()}"

    cond do
      account.uri != published -> [%{id: source["id"], was: published, now: account.uri}]
      generated != published -> [%{id: source["id"], was: published, now: generated}]
      handle != subject -> [%{id: source["id"], was: subject, now: handle}]
      true -> []
    end
  end

  # Every local account the source has, a page at a time, so that neither check
  # holds more than a page in memory.
  defp scan(opts, examine) do
    Batch.scan(opts, "SELECT * FROM #{table(opts, "accounts")} WHERE domain IS NULL", examine)
  end

  ## Paging

  defp copy(opts, part, schema, sql, mapper),
    do: Batch.copy(opts, step_name(part), schema, sql, mapper)

  defp page(opts, part, schema, sql, builder),
    do: Batch.page(opts, step_name(part), schema, sql, builder)

  defp step_name(part), do: Batch.step_name(:identity, part)

  ## Plumbing

  defp rows(opts, sql, params \\ []), do: Source.rows(opts, sql, params)

  defp table(opts, name), do: Source.table(opts, name)

  defp presence(value), do: Source.presence(value)

  defp at(value), do: Source.at(value)
end

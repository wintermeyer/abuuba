defmodule Abuuba.Federation.ResolveActor do
  @moduledoc """
  Turning an actor URI into an account row we can trust a little.

  Everything here is defensive, because the input is a document a stranger
  wrote. Four things are checked before a single field is stored.

  **The document has to be an actor.** A type we do not recognise, a missing
  inbox, an id that is not HTTPS: refused. An actor with no inbox cannot be
  delivered to, and storing it means a follow that silently goes nowhere.

  **The id has to match where we fetched it.** A document is only allowed to
  describe an actor on the host that served it. Otherwise `evil.example` hands
  back a document with `"id": "https://good.example/users/alice"` and we file
  it as Alice.

  **The handle has to check out.** The `preferredUsername` plus the host is a
  claim, and the loopback check is what makes it true; see
  `Abuuba.Federation.WebFinger`.

  **A new host has a budget.** See `Abuuba.Federation.DomainBudget`.

  ## Renames

  Both directions happen and they are different problems. An actor keeping its
  URI and changing its `preferredUsername` is a rename, and the account row
  follows it. A handle that now resolves to a different URI is a different
  actor wearing the same name: the old row keeps its URI and the new one is a
  new account, because the URI is the identity and the handle is only a label.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.DomainBudget
  alias Abuuba.Federation.HTTP
  alias Abuuba.Federation.Limits
  alias Abuuba.Federation.URIs
  alias Abuuba.Federation.WebFinger
  alias Abuuba.Instance
  alias Abuuba.Media.ProfileImages
  alias Abuuba.Repo

  @actor_types ~w(Person Service Application Group Organization)

  # A remote profile changes rarely and a fetch costs somebody else a request.
  @refresh_after_seconds 24 * 60 * 60

  @doc """
  Fetches and stores the actor at `uri`, or returns the one we already have if
  it is fresh enough.
  """
  @spec resolve(String.t(), keyword()) ::
          {:ok, Account.t()} | {:error, atom()}
  def resolve(uri, opts \\ []) do
    case existing(uri) do
      %Account{} = account ->
        if stale?(account, opts), do: refetch(uri, account, opts), else: {:ok, account}

      nil ->
        fetch_and_store(uri, nil, opts)
    end
  end

  @doc """
  Fetches the actor again whatever its age. For a `Update` activity, which is a
  peer telling us its profile changed.
  """
  @spec refresh(String.t(), keyword()) :: {:ok, Account.t()} | {:error, atom()}
  def refresh(uri, opts \\ []) do
    fetch_and_store(uri, existing(uri), opts)
  end

  defp refetch(uri, account, opts) do
    case fetch_and_store(uri, account, opts) do
      {:ok, updated} -> {:ok, updated}
      # A refresh that fails is not a reason to lose what we already had.
      # The peer may be down; the account still exists.
      {:error, _reason} -> {:ok, account}
    end
  end

  # The fetch is outside the lock and outside any transaction, and only the
  # write is inside. It used to be one transaction around both, which held a
  # database connection for as long as a stranger's server took to answer: five
  # seconds to connect and ten to reply, per actor. Ten of those at once is the
  # whole pool, and a peer naming actors on a host that accepts connections and
  # never replies could stall every query on this server.
  #
  # What that costs: two requests naming the same unknown actor at the same
  # moment now both fetch it, where before one waited and found the row
  # already there. The write is still serialised, so the duplicate is a wasted
  # request to somebody else's server rather than a wrong row -- and the
  # re-read below turns the loser into an update instead of a second insert.
  defp fetch_and_store(uri, existing_account, opts) do
    with :ok <- check_uri(uri),
         {:ok, document} <- HTTP.fetch_json(uri, opts),
         :ok <- check_document(document, uri),
         {:ok, handle} <- handle_from(document, uri),
         :ok <- check_loopback(handle, document["id"], opts),
         :ok <- check_budget(existing_account, handle) do
      store(uri, document, handle, existing_account)
    end
  end

  defp store(uri, document, handle, existing_account) do
    with_lock(uri, fn ->
      # Read again under the lock: whoever else was fetching this actor may
      # have written it while we were waiting, and the row that exists now is
      # the one to update.
      with {:ok, account} <- upsert(document, handle, existing_account || existing(uri)) do
        store_public_key(account, document)

        {:ok, account}
      end
    end)
  end

  @doc """
  The account a key id belongs to, fetching it if we have never seen it.

  A key id that is an actor uri plus a fragment names its actor outright, and
  that is most of the network. Anything else has to be asked, and asking is not
  the same as resolving the key id as an actor: GoToSocial serves a stub at its
  key URL with no `inbox`, which is refused as an actor and rightly so. The
  document there says whose key it is, in `owner`, and that is the actor to
  resolve.

  The owner has to be on the same host as the key. A document speaks for its
  own server and no other, so one claiming a key belongs to somebody elsewhere
  is claiming to speak for them.
  """
  @spec resolve_key_owner(String.t(), keyword()) :: {:ok, Account.t()} | {:error, atom()}
  def resolve_key_owner(key_id, opts \\ []) do
    case String.split(key_id, "#", parts: 2) do
      [actor_uri, _fragment] -> resolve(actor_uri, opts)
      _no_fragment -> resolve_owner_of(key_id, opts)
    end
  end

  defp resolve_owner_of(key_id, opts) do
    with {:ok, document} <- HTTP.fetch_json(key_id, opts),
         owner when is_binary(owner) <- owner_uri(document),
         true <- URIs.same_host?(owner, key_id) do
      resolve(owner, opts)
    else
      _unusable -> {:error, :key_owner_unknown}
    end
  end

  # `owner` is what FEP-521a and every implementation of it name. The
  # document's own id is the same answer where a server serves a stub actor
  # rather than a bare key.
  defp owner_uri(%{"publicKey" => %{"owner" => owner}}) when is_binary(owner), do: owner
  defp owner_uri(%{"owner" => owner}) when is_binary(owner), do: owner
  defp owner_uri(%{"id" => id}) when is_binary(id), do: id
  defp owner_uri(_document), do: nil

  ## Checks

  defp check_uri(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _ -> {:error, :insecure_actor_uri}
    end
  end

  defp check_document(document, requested_uri) do
    cond do
      not is_map(document) -> {:error, :malformed_actor}
      document["type"] not in @actor_types -> {:error, :not_an_actor}
      not is_binary(document["id"]) -> {:error, :malformed_actor}
      not URIs.same_host?(document["id"], requested_uri) -> {:error, :actor_host_mismatch}
      is_nil(inbox(document)) -> {:error, :actor_without_inbox}
      true -> :ok
    end
  end

  # A document may only describe an actor on the host that served it.
  # Otherwise a hostile server hands back a document claiming to be somebody
  # on another host and we file it under their name.

  @doc """
  Resolves whatever somebody typed: an address, or a handle.

  Search with `resolve=true` is handed both, and they are found different ways
  — an address is fetched, a handle has to be asked about at the server it
  names. Deciding here rather than at the endpoint, because this is where the
  other half of the decision already lives, and because a caller that gets it
  wrong answers "no such person" about somebody who is plainly there.

  A handle is `user@host`, with or without the `@` in front that everybody
  writes and nothing stores.
  """
  @spec resolve_query(String.t(), keyword()) :: {:ok, Account.t()} | {:error, term()}
  def resolve_query(query, opts \\ [])

  def resolve_query(query, opts) when is_binary(query) do
    trimmed = String.trim(query)

    if handle?(trimmed) do
      resolve_handle(String.trim_leading(trimmed, "@"), opts)
    else
      resolve(trimmed, opts)
    end
  end

  def resolve_query(_query, _opts), do: {:error, :not_found}

  @doc """
  Whether a query is something `resolve_query/2` could go and fetch.

  An address or a complete handle. Asked by the search endpoint, which sends
  everything else to the ordinary database search — and used to send handles
  there too, so `resolve=true` never reached this module at all for the one
  thing people paste most.
  """
  @spec resolvable?(String.t()) :: boolean()
  def resolvable?(query) when is_binary(query) do
    trimmed = String.trim(query)

    url?(trimmed) or handle?(trimmed)
  end

  def resolvable?(_query), do: false

  defp url?(query) do
    match?(%URI{scheme: scheme} when scheme in ["http", "https"], URI.parse(query))
  end

  # Not a URL, and shaped like a name at a host. `https://a.example/@bob` has
  # an `@` in it and is an address; this is the difference.
  defp handle?(query) do
    not String.contains?(query, "://") and
      query |> String.trim_leading("@") |> String.split("@") |> length() == 2
  end

  @doc """
  The account behind a handle, fetching it if this server has never met it.

  `bob@other.example` is what a person types and what every exported list
  writes, and it is two questions: which address does that server say the
  handle is, and what is at that address. WebFinger answers the first and
  `resolve/2` answers the second.

  Local handles are answered from here without a request, because asking
  another server about our own accounts would be absurd and slow.
  """
  @spec resolve_handle(String.t(), keyword()) :: {:ok, Account.t()} | {:error, term()}
  def resolve_handle(handle, opts \\ []) do
    case Accounts.lookup(handle) do
      %Account{} = account ->
        {:ok, account}

      nil ->
        # `lookup/2` answers with the JRD the other server served, and the
        # address is one link inside it. Matching `%{uri: uri}` on that never
        # matched anything, so this returned the document itself and the fetch
        # below never ran: a handle for somebody this server had not met
        # resolved to nothing, quietly, wherever it was asked from.
        with {:ok, jrd} <- WebFinger.lookup(handle, fetch: webfinger_fetcher(opts)),
             {:ok, uri} <- WebFinger.self_link(jrd) do
          resolve(uri, opts)
        else
          :error -> {:error, :not_found}
          other -> other
        end
    end
  end

  defp handle_from(document, uri) do
    username = document["preferredUsername"]
    host = URI.parse(document["id"] || uri).host

    if is_binary(username) and username != "" and is_binary(host) do
      {:ok, "#{username}@#{host}"}
    else
      {:error, :actor_without_username}
    end
  end

  defp check_loopback(handle, actor_id, opts) do
    case Keyword.get(opts, :verify_loopback, true) do
      false ->
        :ok

      _ ->
        WebFinger.verify_loopback(handle, actor_id, fetch: webfinger_fetcher(opts))
    end
  end

  # `get_rest_json/2` rather than `get_json/2`, for two reasons that both bite.
  #
  # A WebFinger answer is `application/jrd+json` — RFC 7033 says so and every
  # implementation sends it — and `get_json/2` requires an ActivityPub content
  # type, so it refused every correct answer any server has ever given.
  #
  # And WebFinger is public discovery, not an ActivityPub fetch: it is not
  # behind authorized fetch anywhere, and signing it only made the request
  # bigger.
  defp webfinger_fetcher(opts) do
    Keyword.get(opts, :webfinger_fetch, fn url ->
      case HTTP.get_rest_json(url, opts) do
        {:ok, document} -> {:ok, 200, Jason.encode!(document)}
        {:error, :gone} -> {:ok, 410, ""}
        {:error, :not_found} -> {:ok, 404, ""}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # Refreshing an actor we already hold never spends budget; only meeting a new
  # host does.
  defp check_budget(%Account{}, _handle), do: :ok

  defp check_budget(nil, handle) do
    [_username, domain] = String.split(handle, "@")

    DomainBudget.spend(domain)
  end

  ## Storing

  defp upsert(document, handle, existing_account) do
    [username, domain] = String.split(handle, "@")
    attrs = attributes(document, username, domain)

    # Their emoji, kept under their domain, so a display name reading
    # `alice :blobcat:` renders their picture rather than the shortcode. Before
    # the account is written, because the write is what a caller waits on and
    # this is a note in the margin of it.
    Instance.put_remote_emoji(List.wrap(document["tag"]), domain)

    case existing_account || by_handle(username, domain) do
      nil -> Accounts.create_account(attrs)
      account -> rename_or_update(account, attrs, document)
    end
  end

  # Both rename directions land on the same row, for different reasons.
  #
  # An actor that kept its URI and changed its `preferredUsername` is plainly
  # the same account renamed.
  #
  # A handle that now resolves to a different URI is the more awkward case: the
  # remote host deleted an account and made a new one with the same name. There
  # cannot be two rows here, because a handle is unique per host and the unique
  # index says so, and the host's own WebFinger has just told us the handle
  # belongs to this URI. So the row follows the handle and takes the new URI.
  #
  # The cost is real and worth stating: whoever now holds that name inherits
  # the followers our side had for the previous holder. The alternative is
  # refusing to resolve the handle at all, which breaks every mention of a
  # perfectly ordinary recreated account.
  defp rename_or_update(%Account{} = account, attrs, _document) do
    Accounts.update_account(account, attrs)
  end

  defp by_handle(username, domain), do: Accounts.get_account_by_handle(username, domain)

  defp attributes(document, username, domain) do
    %{
      username: username,
      domain: domain,
      uri: document["id"],
      url: document["url"] || document["id"],
      actor_type: Account.actor_type(document["type"]),
      display_name: Limits.name(document["name"]),
      note: Limits.summary(document["summary"]),
      inbox_url: inbox(document),
      shared_inbox_url: shared_inbox(document),
      outbox_url: string_or_nil(document["outbox"]),
      followers_url: string_or_nil(document["followers"]),
      following_url: string_or_nil(document["following"]),
      locked: document["manuallyApprovesFollowers"] == true,
      bot: Account.bot?(document["type"]),
      discoverable: document["discoverable"] == true,
      indexable: document["indexable"] == true,
      memorial: document["memorial"] == true,
      attribution_domains: string_list(document["attributionDomains"]),
      also_known_as: uri_list(document["alsoKnownAs"]),
      fields: fields(document["attachment"]),
      last_fetched_at: DateTime.utc_now()
    }
    |> Map.merge(ProfileImages.remote_attrs(document))
  end

  defp inbox(document) do
    string_or_nil(document["inbox"])
  end

  defp shared_inbox(document) do
    case document["endpoints"] do
      %{"sharedInbox" => uri} -> string_or_nil(uri)
      _ -> nil
    end
  end

  # Only PropertyValue attachments are profile fields. The same key carries
  # images on a post, so taking everything would file a picture as a field.
  # How many, and how long each may be, is `Abuuba.Federation.Limits`.
  defp fields(attachment) when is_list(attachment) do
    attachment
    |> Enum.filter(&(is_map(&1) and &1["type"] == "PropertyValue"))
    |> Limits.fields()
  end

  defp fields(_attachment), do: []

  # Somebody else's list, so it is taken as strings and trimmed to what this
  # server will compare against: a host, lower case, without the scheme or the
  # `*.` a person may have typed on their own server.
  defp string_list(value) do
    value
    |> uri_list()
    |> Enum.map(fn domain ->
      domain
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("*.", "")
      |> String.trim_trailing("/")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(100)
  end

  defp uri_list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp uri_list(value) when is_binary(value), do: [value]
  defp uri_list(_value), do: []

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  # Stored as a keypair row with no private half, which is what a remote key is:
  # something we can verify with and never sign with.
  defp store_public_key(account, document) do
    case document["publicKey"] do
      %{"publicKeyPem" => pem} = key when is_binary(pem) ->
        replace_key(account, pem, string_or_nil(key["id"]))

      _ ->
        :ok
    end
  end

  # The id is kept as the peer wrote it rather than rebuilt from the actor's
  # uri. A signature names its key and nothing else, and the shape of that name
  # is the peer's to choose: Mastodon writes a fragment, GoToSocial writes a
  # path, and there is no rule that either is the only way.
  defp replace_key(account, pem, key_id) do
    existing =
      Keypair
      |> where([k], k.account_id == ^account.id and is_nil(k.private_key))
      |> Repo.one()

    case existing do
      nil ->
        %Keypair{}
        |> Keypair.changeset(%{
          account_id: account.id,
          public_key: pem,
          key_id: key_id,
          type: :rsa_2048
        })
        |> Repo.insert()

      %Keypair{public_key: ^pem, key_id: ^key_id} ->
        :ok

      # A key that changed is a rotation, and the new one replaces the old:
      # keeping both would let a compromised key keep verifying. An id that
      # changed while the key did not is a peer that renamed it, and the new
      # name is the one their signatures will carry.
      keypair ->
        keypair
        |> Ecto.Changeset.change(public_key: pem, key_id: key_id)
        |> Repo.update()
    end
  end

  ## Freshness and locking

  defp existing(uri), do: Repo.get_by(Account, uri: uri)

  defp stale?(%Account{last_fetched_at: nil}, _opts), do: true

  defp stale?(%Account{last_fetched_at: at}, opts) do
    max_age = Keyword.get(opts, :max_age_seconds, @refresh_after_seconds)

    DateTime.diff(DateTime.utc_now(), at, :second) > max_age
  end

  # A Postgres advisory lock rather than one in this node's memory, because two
  # nodes resolving the same actor at the same moment is the case this is for.
  # Transaction-scoped, so it is released even if the work below crashes.
  defp with_lock(uri, work) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key(uri)])

      case work.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_key(uri) do
    <<key::signed-integer-64, _rest::binary>> = :crypto.hash(:sha256, uri)

    key
  end

  @doc """
  How old a stored actor may be before it is fetched again.
  """
  def refresh_after_seconds, do: @refresh_after_seconds
end

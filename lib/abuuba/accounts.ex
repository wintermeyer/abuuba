defmodule Abuuba.Accounts do
  @moduledoc """
  Actors, the local users behind them, and their signing keys.

  See `Abuuba.Accounts.Account` for why local and remote actors share one table.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Keypair
  alias Abuuba.Accounts.LinkVerificationWorker
  alias Abuuba.Accounts.User
  alias Abuuba.Exports
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Federation.Outbox
  alias Abuuba.Federation.URIs
  alias Abuuba.Media
  alias Abuuba.Media.ProfileImages
  alias Abuuba.Repo
  alias Abuuba.Timelines.Feed
  alias Abuuba.Webhooks

  # Ids below zero belong to actors abuuba creates for itself rather than for a
  # person. The instance actor is the one that signs server-to-server requests
  # such as fetching a remote object, so that those are attributable to the
  # server and not to whichever user happened to trigger them. Its id is fixed
  # rather than generated because other servers cache the actor by URL, and
  # that URL must survive a database being rebuilt.
  @instance_actor_id -99

  @doc """
  The reserved id of this server's own actor.
  """
  @spec instance_actor_id() :: integer()
  def instance_actor_id, do: @instance_actor_id

  @doc """
  Whether an id belongs to the reserved range for abuuba's own actors.
  """
  @spec internal_actor_id?(integer()) :: boolean()
  def internal_actor_id?(id) when is_integer(id), do: id < 0

  ## Accounts

  @doc """
  Creates an account. Pass `domain` for a remote actor and leave it out for a
  local one.
  """
  @spec create_account(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_account(attrs) do
    %Account{} |> Account.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Creates an actor the server owns, at a fixed id in the reserved range.

  Used for the instance actor. Ordinary accounts must go through
  `create_account/1`, which cannot set an id.
  """
  @spec create_internal_actor(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_internal_actor(attrs) do
    %Account{} |> Account.internal_changeset(attrs) |> Repo.insert()
  end

  @doc """
  Updates an account from trusted input.

  Reaches every column, moderation state and federation endpoints included, so
  it must never be given parameters that came from the account's owner. Use
  `update_profile/2` for those and `update_moderation/2` for a moderator.
  """
  @spec update_account(Account.t(), map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def update_account(%Account{} = account, attrs) do
    account |> Account.changeset(attrs) |> Repo.update() |> tap(&announce_update/1)
  end

  @doc """
  Updates the parts of an account its owner may edit. Safe for request params.
  """
  @spec update_profile(Account.t(), map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%Account{} = account, attrs) do
    account
    |> Account.profile_changeset(attrs)
    |> Repo.update()
    |> tap(fn
      # Peers cache a profile until something tells them otherwise, so without
      # this a changed name or note stays wrong everywhere else until their
      # next scheduled refresh, which can be days.
      {:ok, updated} = result ->
        Outbox.profile_updated(updated)
        # A new link is worth looking at now rather than at the next sweep,
        # which is a week away.
        LinkVerificationWorker.enqueue(updated)
        announce_update(result)

      _ ->
        :ok
    end)
  end

  @doc """
  Sets an account's moderation state. For moderators only; callers are
  responsible for checking that.
  """
  @spec update_moderation(Account.t(), map()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def update_moderation(%Account{} = account, attrs) do
    account |> Account.moderation_changeset(attrs) |> Repo.update() |> tap(&announce_update/1)
  end

  # Local accounts only. A remote one changes every time this server refetches
  # its actor, and an integration watching for "somebody here edited their
  # profile" does not want a stream of other servers' profile churn.
  #
  # The payload matches the other two account events, and carries no more than
  # they do for the same reason the status events carry no text: a receiver
  # that wants the details can fetch them, and a webhook body is a copy of
  # somebody's page sitting in somebody else's logs.
  defp announce_update({:ok, %Account{domain: nil} = account}) do
    Webhooks.announce("account.updated", %{
      "id" => to_string(account.id),
      "username" => account.username,
      "created_at" => DateTime.to_iso8601(account.inserted_at)
    })
  end

  defp announce_update(_result), do: :ok

  @doc """
  The accounts among these ids that anybody may be shown.

  For a client that has a page of ids and would otherwise ask for each one on
  its own. An id nobody answers to is simply absent from the answer.

  A local account whose owner has not confirmed their address, or whom a
  moderator has not let in yet, is left out. Their profile does not exist for
  anybody else yet, and a batch fetch must not be the way around that. Remote
  accounts have no such state for us to check and are shown whenever they are
  not suspended.
  """
  @spec visible_by_ids([integer()]) :: [Account.t()]
  def visible_by_ids([]), do: []

  def visible_by_ids(ids) do
    from(a in Account,
      left_join: u in User,
      on: u.account_id == a.id,
      where: a.id in ^ids and is_nil(a.suspended_at),
      where: not is_nil(a.domain) or (u.approved and not is_nil(u.confirmed_at)),
      order_by: [asc: a.id]
    )
    |> Repo.all()
  end

  @doc """
  Fetches an account by id, or `nil`.
  """
  @spec get_account(integer()) :: Account.t() | nil
  def get_account(id), do: Repo.get(Account, id)

  @doc """
  Accounts by id, as a map keyed by id.

  For rendering a page that names many people: one query for the page rather
  than one per name.
  """
  @spec get_accounts([integer()]) :: %{integer() => Account.t()}
  def get_accounts([]), do: %{}

  def get_accounts(ids) do
    Account
    |> where([a], a.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Fetches an account by handle. `domain` is `nil` for a local account.

  Both halves are matched case-insensitively, because a handle is
  case-insensitive everywhere on the fediverse and the same person may be
  written `@Alice@Example.com` on one server and `@alice@example.com` on
  another.
  """
  @spec get_account_by_handle(String.t(), String.t() | nil) :: Account.t() | nil
  def get_account_by_handle(username, domain \\ nil) do
    Account
    |> where([a], fragment("lower(?)", a.username) == ^String.downcase(username))
    |> where(
      [a],
      fragment("coalesce(lower(?), '')", a.domain) == ^String.downcase(domain || "")
    )
    |> Repo.one()
  end

  ## Users

  @doc """
  Creates the local user record for an account.
  """
  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{} |> User.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Saves a user's language preference.

  Refuses a locale we have no translations for rather than storing it: a saved
  preference outranks the browser's, so an unknown one would leave somebody
  stuck being answered in msgids with no obvious way back.
  """
  @spec update_user_locale(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_locale(%User{} = user, locale) do
    user
    |> User.locale_changeset(%{locale: locale})
    |> Repo.update()
  end

  @doc """
  Fetches the user belonging to an account, or `nil` for a remote actor.
  """
  @spec get_user_by_account(Account.t() | integer()) :: User.t() | nil
  def get_user_by_account(%Account{id: id}), do: get_user_by_account(id)
  def get_user_by_account(account_id), do: Repo.get_by(User, account_id: account_id)

  ## Keys

  @doc """
  Generates and stores a signing keypair for a local account.
  """
  @spec create_keypair(Account.t() | integer()) ::
          {:ok, Keypair.t()} | {:error, Ecto.Changeset.t()}
  def create_keypair(%Account{id: id}), do: create_keypair(id)

  def create_keypair(account_id) do
    attrs = Keypair.generate() |> Map.put(:account_id, account_id)

    with {:ok, keypair} <- %Keypair{} |> Keypair.changeset(attrs) |> Repo.insert() do
      # A new key means anything signing with the old one must stop now, not
      # when a cache entry happens to lapse.
      InstanceActor.invalidate_signing_key()

      {:ok, keypair}
    end
  end

  @doc """
  The key an account currently signs with, or `nil`.
  """
  @spec active_keypair(Account.t() | integer()) :: Keypair.t() | nil
  def active_keypair(%Account{id: id}), do: active_keypair(id)

  def active_keypair(account_id) do
    Keypair
    |> where([k], k.account_id == ^account_id)
    |> where([k], is_nil(k.revoked_at) and not is_nil(k.private_key))
    |> Repo.one()
    |> reject_expired()
  end

  defp reject_expired(nil), do: nil

  defp reject_expired(%Keypair{} = keypair) do
    # Say plainly what went wrong. Left alone this surfaces much later as a
    # crash inside PEM decoding, which reads like a corrupt key rather than a
    # misconfigured server.
    if Keypair.undecryptable?(keypair) do
      raise """
      the private key of account #{keypair.account_id} did not decrypt.

      CLOAK_KEY is not the key this row was written with. Restore the original
      key rather than generating a new one: re-keying means every account has
      to be re-federated.
      """
    end

    if Keypair.active?(keypair), do: keypair, else: nil
  end

  @doc """
  Revokes a keypair, which frees the account to be given a new one.
  """
  @spec revoke_keypair(Keypair.t()) :: {:ok, Keypair.t()} | {:error, Ecto.Changeset.t()}
  def revoke_keypair(%Keypair{} = keypair) do
    with {:ok, revoked} <- keypair |> Keypair.revoke_changeset() |> Repo.update() do
      # A key revoked without a successor must stop signing now, not when its
      # cache entry lapses.
      InstanceActor.invalidate_signing_key()

      {:ok, revoked}
    end
  end

  @doc """
  Replaces an account's signing key with a fresh one.

  Revoking and creating are one transaction because the partial unique index
  allows only one live key per account: done as two steps, a failure in between
  leaves the account unable to sign at all. This is also the only way past an
  expired key, since `create_keypair/1` alone would trip over the index, which
  cannot know about expiry (its predicate has to be immutable).

  The old row stays, with its public half readable, so signatures already
  delivered to other servers can still be verified.
  """
  @spec rotate_keypair(Account.t() | integer()) ::
          {:ok, Keypair.t()} | {:error, Ecto.Changeset.t()}
  def rotate_keypair(%Account{id: id}), do: rotate_keypair(id)

  def rotate_keypair(account_id) do
    result =
      Repo.transaction(fn ->
        case current_private_keypair(account_id) do
          nil -> :ok
          keypair -> {:ok, _} = revoke_keypair(keypair)
        end

        case create_keypair(account_id) do
          {:ok, keypair} -> keypair
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    with {:ok, _keypair} <- result do
      # The invalidations inside the transaction fired before its commit, so
      # a concurrent signer may have re-cached the old key in between. This
      # one runs after the new key is visible, which closes that window.
      InstanceActor.invalidate_signing_key()

      result
    end
  end

  # The row occupying the account's slot in the partial unique index, expired
  # or not. `active_keypair/1` answers a different question: what may sign now.
  defp current_private_keypair(account_id) do
    Keypair
    |> where([k], k.account_id == ^account_id)
    |> where([k], is_nil(k.revoked_at) and not is_nil(k.private_key))
    |> Repo.one()
  end

  @doc """
  Finds an account by the handle somebody typed.

  Accepts `alice`, `@alice`, `alice@example.social` and `@alice@example.social`,
  because all four are what people paste. A handle naming this server's own
  domain is the local account, not a remote one that happens to share the name.
  """
  @spec lookup(String.t() | nil) :: Account.t() | nil
  def lookup(nil), do: nil

  def lookup(handle) when is_binary(handle) do
    case handle |> String.trim() |> String.trim_leading("@") |> String.split("@") do
      [username] -> get_account_by_handle(username, nil)
      [username, domain] -> lookup_with_domain(username, domain)
      _ -> nil
    end
  end

  def lookup(_handle), do: nil

  @doc """
  The same for several handles at once, keyed by the handle as it was given.

  One query rather than one per handle. The compose box renders a preview of
  what is being written on every keystroke, and resolving each `@mention`
  separately made a post naming four people four round trips per render.

  Handles that name nobody are simply absent, the way `lookup/1` answers `nil`.
  """
  @spec lookup_many([String.t()]) :: %{String.t() => Account.t()}
  def lookup_many([]), do: %{}

  def lookup_many(handles) do
    wanted =
      handles
      |> Enum.uniq()
      |> Enum.flat_map(fn handle ->
        case split_handle(handle) do
          nil -> []
          pair -> [{handle, pair}]
        end
      end)

    found = accounts_by_handle(wanted |> Enum.map(&elem(&1, 1)) |> Enum.uniq())

    wanted
    |> Enum.flat_map(fn {handle, pair} ->
      case Map.get(found, pair) do
        nil -> []
        account -> [{handle, account}]
      end
    end)
    |> Map.new()
  end

  defp accounts_by_handle([]), do: %{}

  defp accounts_by_handle(pairs) do
    pairs
    |> Enum.reduce(Account, fn {username, domain}, query ->
      or_where(
        query,
        [a],
        fragment("lower(?)", a.username) == ^username and
          fragment("coalesce(lower(?), '')", a.domain) == ^domain
      )
    end)
    |> Repo.all()
    |> Map.new(&{{String.downcase(&1.username), String.downcase(&1.domain || "")}, &1})
  end

  # The three shapes `lookup/1` accepts, as the pair the column comparison
  # wants: a handle naming this server's own domain is the local account.
  defp split_handle(handle) when is_binary(handle) do
    case handle |> String.trim() |> String.trim_leading("@") |> String.split("@") do
      [username] ->
        {String.downcase(username), ""}

      [username, domain] ->
        if URIs.local_domain?(domain),
          do: {String.downcase(username), ""},
          else: {String.downcase(username), String.downcase(domain)}

      _ ->
        nil
    end
  end

  defp split_handle(_handle), do: nil

  defp lookup_with_domain(username, domain) do
    if URIs.local_domain?(domain) do
      get_account_by_handle(username, nil)
    else
      get_account_by_handle(username, domain)
    end
  end

  @doc """
  Accounts matching what somebody typed into a search box.

  Prefix matching on the username and the display name, which is what somebody
  half-typing a name is doing. Suspended accounts are left out: a moderator
  suspended them, and a search box is not the place to argue with that.

  Not full-text search, which arrives with its own issue. This is the "find the
  person I am about to mention" path, and it has to be fast and predictable
  rather than clever.
  """
  @spec search(String.t() | nil, keyword()) :: [Account.t()]
  def search(query, opts \\ [])
  def search(nil, _opts), do: []

  def search(query, opts) when is_binary(query) do
    term = query |> String.trim() |> String.trim_leading("@")

    if term == "" do
      []
    else
      pattern = escape_like(term) <> "%"

      Account
      |> where([a], is_nil(a.suspended_at))
      |> where(
        [a],
        ilike(a.username, ^pattern) or ilike(a.display_name, ^pattern)
      )
      |> maybe_local_only(Keyword.get(opts, :local, false))
      |> order_by([a], asc: fragment("length(?)", a.username), asc: a.id)
      |> limit(^Keyword.get(opts, :limit, 40))
      |> Repo.all()
    end
  end

  def search(_query, _opts), do: []

  defp maybe_local_only(query, true), do: where(query, [a], is_nil(a.domain))
  defp maybe_local_only(query, _local), do: query

  # `%` and `_` are wildcards in LIKE, so a search for "100%" would otherwise
  # match everything beginning with "100".
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Accounts a server is willing to list publicly.

  Only accounts that asked to be discoverable, and only local ones: a directory
  of everybody a server has ever heard of is a directory of the fediverse, not
  of this instance, and nobody on another server agreed to appear in it.
  """
  @spec directory(keyword()) :: [Account.t()]
  def directory(opts \\ []) do
    Account
    |> where([a], is_nil(a.suspended_at) and a.discoverable)
    # Limiting an account says it should not be put in front of people who did
    # not ask for it, which is what a directory does. Suggestions, trends and
    # the admin's popular list all left them out already; this was the one
    # place that still offered them.
    |> where([a], is_nil(a.silenced_at))
    # And somebody who has moved: the listing should send people to the account
    # that will answer, not to the one they left.
    |> where([a], is_nil(a.moved_to_account_id))
    |> where([a], is_nil(a.domain))
    |> directory_order(Keyword.get(opts, :order, "active"))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> limit(^Keyword.get(opts, :limit, 40))
    |> Repo.all()
  end

  # Local only, deliberately, where the reference implementation also lists
  # remote discoverables: somebody elsewhere set that flag for their own
  # server's directory and never agreed to appear in ours. `local=true` from a
  # client is therefore satisfied trivially rather than being a switch.

  # Active is the default, as it is upstream, because it is what every
  # client's "explore people" tab asks for -- and the parameter was silently
  # ignored, so whoever registered last stood first however long they had
  # been quiet. Nulls last: an account that never posted belongs at the end
  # of an activity ordering, not raised to the top by a null comparing high.
  defp directory_order(query, "new"), do: order_by(query, [a], desc: a.id)

  defp directory_order(query, _active) do
    query
    |> join(:left, [a], st in "account_stats", on: st.account_id == a.id)
    |> order_by([a, st], desc_nulls_last: st.last_status_at, desc: a.id)
  end

  @doc """
  An account by its ActivityPub id or its profile URL, without fetching one.

  One resolver for both directions. A remote account is found in the column its
  server's id was written to; one of ours is read out of the URI, because a
  local account has no `uri` — the id this server publishes is derived from the
  row. Every caller goes through here so the two cannot drift apart again,
  which they had: the column lookup silently answered `nil` for every local
  account and half the inbound handlers dropped what they were given.
  """
  @spec get_account_by_uri(String.t() | nil) :: Account.t() | nil
  def get_account_by_uri(uri) when is_binary(uri) do
    case URIs.parse_local(uri) do
      {:account, username} -> get_account_by_handle(username, nil)
      {:account_id, id} -> local_account_by_id(id)
      {:status, _id} -> nil
      :error -> Account |> where([a], a.uri == ^uri or a.url == ^uri) |> limit(1) |> Repo.one()
    end
  end

  def get_account_by_uri(_uri), do: nil

  defp local_account_by_id(id) do
    case Repo.get(Account, id) do
      %Account{domain: nil} = account -> account
      _ -> nil
    end
  end

  @doc """
  Removes an account and everything that hangs off it.

  The feed goes explicitly. `feed_entries` names an account by id with no
  foreign key behind it, on purpose: a key would put a lock on `accounts` in
  the path of every fan-out insert. So deletion clears it here rather than
  leaving it for a sweeper somebody has to notice is behind.
  """
  @spec delete_account(Account.t()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def delete_account(%Account{} = account) do
    # One transaction, because the retraction below is not recoverable on its
    # own: it subtracts the account's contribution from counters using rows
    # that the delete is about to take away, so a delete that fails after it
    # would leave every one of those numbers short with nothing left to
    # recount from.
    Repo.transaction(fn ->
      Feed.clear("home", account.id)

      # Before the delete, while `account_id` still points at them: the
      # attachment rows are `nilify_all` rather than `delete_all`, so the
      # cascade that takes the posts would leave the pictures behind as rows
      # owned by nobody and bytes nothing names. The settings page says an
      # account's things are deleted, and these are somebody's photographs.
      {:ok, _dropped} = Media.discard_for_account(account.id)

      # And the two that are columns rather than rows. Nothing cascades them
      # and the orphan sweep cannot find them, because it looks for attachment
      # rows with no post and a profile picture has never been one.
      Enum.each(ProfileImages.kinds(), &ProfileImages.remove(account, &1))

      # And the archives. Those rows are `delete_all`, so the cascade would
      # take them and leave the zips behind: the sweep that removes a file only
      # sees rows past their expiry, and a deleted row never gets there.
      {:ok, _archives} = Exports.discard_for_account(account.id)

      # Before the delete, while the rows still exist to count: the cascades
      # take the account's favourites, boosts, replies and follows with them,
      # and every counter those rows moved has to move back.
      Abuuba.Stats.retract_account(account.id)

      case Repo.delete(account) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Stores a change to somebody's own settings map.

  The whole map rather than a patch, because the caller has already merged what
  it wanted to change: `Abuuba.Accounts.Preferences.merge/2` is what keeps the
  rest of it intact.
  """
  @spec update_user_settings(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_settings(%User{} = user, settings) do
    user
    |> Ecto.Changeset.change(settings: settings)
    |> Repo.update()
  end
end

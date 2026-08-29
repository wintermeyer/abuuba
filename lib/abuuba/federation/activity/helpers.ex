defmodule Abuuba.Federation.Activity.Helpers do
  @moduledoc """
  What every inbound handler needs.

  The two lookups here are deliberately different. An actor named in an
  activity may be somebody we have never met, so resolving one means going and
  fetching it. A local account named as a target is either here or the activity
  is not for us, so that lookup never leaves the database.
  """

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Federation.URIs
  alias Abuuba.Repo

  @doc """
  The account behind an activity's `actor`, fetching it if we have never met.
  """
  @spec actor(map(), keyword()) :: {:ok, Account.t()} | {:error, atom()}
  def actor(activity, opts \\ []) do
    case uri_of(activity["actor"]) do
      nil -> {:error, :actor_missing}
      uri -> resolve(uri, opts)
    end
  end

  @doc """
  Resolves an actor URI to an account.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, Account.t()} | {:error, atom()}
  def resolve(uri, opts) do
    case Keyword.get(opts, :resolve_actor) do
      nil -> ResolveActor.resolve(uri, opts)
      resolver -> resolver.(uri)
    end
  end

  @doc """
  A local account by its actor URI, without ever going out to the network.

  An activity naming a local account we do not have is not for us.

  Read out of the URI rather than looked up in a column. A local account's
  `uri` is `NULL` — the id this server publishes is derived from the row — so
  matching on the column silently answered `nil` for every local account, and
  every inbound activity addressed to one of ours was quietly dropped.
  """
  @spec local_account(String.t() | nil) :: Account.t() | nil
  def local_account(uri) when is_binary(uri) do
    case URIs.parse_local(uri) do
      {:account, username} -> Accounts.get_account_by_handle(username, nil)
      {:account_id, id} -> local_account_by_id(id)
      _ -> nil
    end
  end

  def local_account(_uri), do: nil

  defp local_account_by_id(id) do
    case Repo.get(Account, id) do
      %Account{domain: nil} = account -> account
      _ -> nil
    end
  end

  @doc """
  Any account we already hold, by actor URI.
  """
  @spec known_account(String.t() | nil) :: Account.t() | nil
  def known_account(uri), do: Accounts.get_account_by_uri(uri)

  @doc """
  The URI a field refers to, however it is written: a bare string, an embedded
  object with an id, or the first of a list.
  """
  @spec uri_of(term()) :: String.t() | nil
  def uri_of(value) when is_binary(value), do: value
  def uri_of(%{"id" => id}) when is_binary(id), do: id
  def uri_of([first | _rest]), do: uri_of(first)
  def uri_of(_value), do: nil

  @doc """
  The object an activity carries, as a document if it has one.
  """
  @spec object(map()) :: map() | nil
  def object(%{"object" => %{} = embedded}), do: embedded
  def object(_activity), do: nil

  @doc """
  Whether the sender of an activity may speak for the object it carries.

  The signature binds a request to whoever sent it, and the inbox checks that
  sender against the activity's `actor`. Neither ties either of them to the
  post's author, so without this a server could push an `Update` naming
  somebody else's post and this one would rewrite it — the words, and since
  attachments federate, the pictures too.

  Same host rather than same actor. A server speaks for its own accounts, which
  is what lets an account's own server send on its behalf, and it is the same
  rule `ResolveStatus` already applies between an object's id and the author it
  claims.
  """
  @spec speaks_for?(map(), map()) :: boolean()
  def speaks_for?(activity, object) do
    URIs.same_host?(uri_of(activity["actor"]), uri_of(object["attributedTo"]))
  end
end

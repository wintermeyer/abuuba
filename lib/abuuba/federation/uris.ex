defmodule Abuuba.Federation.URIs do
  @moduledoc """
  The URIs this server hands out for its own actors and objects.

  Kept in one place because they are load-bearing in a way ordinary routes are
  not. Other servers store an actor's `id` and use it as that account's
  permanent name; changing the shape later does not migrate anybody, it orphans
  every follow relationship pointing at the old one. So these are decided once
  and then left alone.

  The host comes from configuration rather than from the request, because a
  request arriving on some other hostname must not be able to make us claim
  actors under it.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Statuses.Conversation

  @doc """
  The domain this server calls itself, as it appears in handles and URIs.
  """
  @spec local_domain() :: String.t()
  def local_domain do
    Application.get_env(:abuuba, :local_domain) ||
      raise """
      :local_domain is not configured.

      It is the host this server calls itself in every URI it hands to other
      servers, and it cannot be taken from the request: a request arriving on
      another hostname would otherwise make us claim actors under it.
      """
  end

  @doc """
  The host a URL lives on, or `nil` where it has none.
  """
  @spec host_of(String.t() | nil) :: String.t() | nil
  def host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  def host_of(_url), do: nil

  @doc """
  Resolves a reference against the address it was found at.

  `nil` where it cannot be resolved at all. Every caller is reading something a
  stranger wrote — a `href` in their markup, a `Location` in their response —
  and a reference that is not one is a broken link on their page rather than an
  error worth failing our work for.
  """
  @spec absolute(String.t() | nil, String.t()) :: String.t() | nil
  def absolute(nil, _base), do: nil

  def absolute(reference, base) do
    base |> URI.merge(reference) |> URI.to_string()
  rescue
    _error -> nil
  end

  @doc """
  Whether two URIs are on the same host.

  Compared by host rather than exactly, because a server legitimately speaks
  for its own actors: an `Accept` from a relay arrives from the relay's actor
  rather than from the inbox URL an admin typed in, and an activity is often
  signed with the instance actor's key rather than the author's.

  Anything that is not a URI with a host is a mismatch rather than a pass. A
  check that cannot be proved does not hold.
  """
  @spec same_host?(String.t() | nil, String.t() | nil) :: boolean()
  def same_host?(a, b) do
    case {host_of(a), host_of(b)} do
      {nil, _} -> false
      {_, nil} -> false
      {host, host} -> true
      _ -> false
    end
  end

  @doc """
  The local domain with any port stripped off.

  A development server calls itself `localhost:4000`, and a colon is not legal
  in the places a bare hostname is wanted: the instance actor is named after
  the host, and its username has to be a username.
  """
  @spec local_host() :: String.t()
  def local_host, do: local_domain() |> String.split(":") |> hd()

  @doc """
  The scheme used for outward-facing URIs. HTTPS everywhere but a dev machine.
  """
  @spec scheme() :: String.t()
  def scheme, do: Application.get_env(:abuuba, :local_scheme, "https")

  @doc """
  The root of this server, without a trailing slash.
  """
  @spec base_url() :: String.t()
  def base_url, do: "#{scheme()}://#{local_domain()}"

  @doc """
  An account's ActivityPub id, which is its permanent name on the fediverse.

  The one place that answers this. `Abuuba.Federation.Actor.id/1` is the name most
  of the codebase calls it by and delegates here, because when the two had a
  clause order of their own they disagreed: this one tried the local shape
  first and so ignored a stored `uri` altogether, which is what the instance
  actor has. WebFinger built its self link from here and the actor was served
  from there, so the document pointed at `/users/abuuba.interop` while the actor
  lived at `/actor`.

  A peer in authorized-fetch mode webfingers the handle behind a signature and
  refuses the request unless the self link loops back to the actor holding the
  key. So those two strings differing was not untidiness: it was every signed
  request abuuba made being refused by such a server, in both directions, with a
  message about webfinger that named neither signatures nor the actor.
  """
  @spec actor_uri(Account.t() | String.t()) :: String.t()
  def actor_uri(%Account{uri: uri}) when is_binary(uri), do: uri

  def actor_uri(%Account{id_scheme: :numeric, id: account_id}),
    do: "#{base_url()}/ap/users/#{account_id}"

  def actor_uri(%Account{username: username}), do: actor_uri(username)
  def actor_uri(username) when is_binary(username), do: "#{base_url()}/users/#{username}"

  @doc """
  The human-facing profile page.
  """
  @spec profile_url(Account.t() | String.t()) :: String.t()
  def profile_url(%Account{domain: nil, username: username}), do: profile_url(username)
  def profile_url(%Account{url: url}) when is_binary(url), do: url

  # A remote actor need not publish a human-facing page, and one that does not
  # still has to render somewhere a reader can click. Its actor URI is the only
  # address we are sure of.
  def profile_url(%Account{uri: uri}) when is_binary(uri), do: uri

  # And a remote row can have neither, because this server can learn that an
  # account exists before it fetches it: a mention, a follower list, the author
  # of a boosted post. Rendering one of those must still produce an address, so
  # it gets this server's own page for it. Guessing a URL on the other server
  # would be a link that 404s, and raising here took down every page that
  # happened to show one of its posts.
  def profile_url(%Account{username: username, domain: domain}) when is_binary(domain),
    do: "#{base_url()}/@#{username}@#{domain}"

  def profile_url(username) when is_binary(username), do: "#{base_url()}/@#{username}"

  @doc """
  The name a thread travels under.

  A conversation is the only thing that holds a thread together when its posts
  arrive out of order, which over asynchronous delivery is ordinary: a reply
  routinely turns up before the post it answers, and `inReplyTo` then names
  something this server has never seen.

  A `tag:` URI rather than an address, deliberately. It is an identifier and
  nothing more — there is no document to fetch at the other end — and the
  scheme exists to say exactly that, so publishing one is not publishing a URL
  this server does not serve. The shape is the reference implementation's,
  which has read and written it for a decade and parses the id back out of it.

  A conversation that arrived from elsewhere keeps the name it arrived with.
  Renaming it would leave a thread spanning three servers with three names for
  itself.
  """
  @spec conversation_uri(Conversation.t()) :: String.t()
  def conversation_uri(%Conversation{uri: uri}) when is_binary(uri) and uri != "", do: uri

  def conversation_uri(%Conversation{id: id, inserted_at: inserted_at}) do
    "tag:#{local_domain()},#{Date.to_iso8601(DateTime.to_date(inserted_at))}:objectId=#{id}:objectType=Conversation"
  end

  @doc """
  The conversation id inside one of our own `tag:` URIs, or `nil`.

  `nil` for anybody else's, which is the answer that matters: a name from
  another server is theirs to keep and ours to record, not to resolve against
  our own rows.
  """
  @spec conversation_id_from(String.t()) :: integer() | nil
  def conversation_id_from(uri) when is_binary(uri) do
    with true <- String.starts_with?(uri, "tag:#{local_domain()},"),
         [_whole, id] <- Regex.run(~r/objectId=(\d+):objectType=Conversation/, uri),
         {id, ""} <- Integer.parse(id) do
      id
    else
      _not_ours -> nil
    end
  end

  def conversation_id_from(_uri), do: nil

  @doc """
  The page a person reads a post on.

  Distinct from the post's ActivityPub id on purpose. The id names the object
  and is what other servers fetch; this is the address a client's "open in a
  browser" goes to and what somebody pastes into a chat. Handing out the id for
  both would send readers to a JSON document.
  """
  @spec status_url(Account.t(), integer()) :: String.t()
  def status_url(%Account{} = account, status_id) do
    "#{profile_url(account)}/#{status_id}"
  end

  @doc """
  The inbox an actor's mail goes to.
  """
  @spec inbox_url(Account.t() | String.t()) :: String.t()
  def inbox_url(account_or_username), do: actor_uri(account_or_username) <> "/inbox"

  @doc """
  The one inbox that takes deliveries for every actor here, so a peer sending
  the same activity to a hundred local followers sends it once.
  """
  @spec shared_inbox_url() :: String.t()
  def shared_inbox_url, do: "#{base_url()}/inbox"

  @doc """
  Reads one of our own URIs back into what it names.

  A local account and a local post have no `uri` column: the id this server
  hands out is *derived* from the row, which is what keeps it from having to be
  written twice and kept in step. The cost is that a URI cannot be looked up in
  a column, so it has to be read. The reference implementation does the same
  for the same reason.

  Returns `{:account, username}`, `{:account_id, id}`, `{:status, id}`, or
  `:error` for anything on another host or in a shape this server never hands
  out. Every id abuuba publishes is one of these:

      https://host/users/alice                     an account
      https://host/ap/users/123                    the same, numeric scheme
      https://host/users/alice/statuses/456        a post
      https://host/users/alice/statuses/456/activity   the Create that carried it
      https://host/ap/users/123/statuses/456       a post, numeric scheme

  A fragment is dropped first: `#main-key`, `#follows/1` and the rest name a
  part of a document rather than a different document.
  """
  @spec parse_local(String.t() | nil) ::
          {:account, String.t()} | {:account_id, integer()} | {:status, integer()} | :error
  def parse_local(uri) when is_binary(uri) do
    parsed = URI.parse(uri)

    if local_host?(parsed) do
      parsed.path |> to_string() |> String.split("/", trim: true) |> match_segments()
    else
      :error
    end
  end

  def parse_local(_uri), do: :error

  # Compared on host and port together, because a development server is
  # `localhost:4000` and an id that dropped the port names a different origin.
  defp local_host?(%URI{host: host} = parsed) when is_binary(host) do
    authority =
      case parsed.port do
        nil -> host
        port -> if default_port?(parsed.scheme, port), do: host, else: "#{host}:#{port}"
      end

    String.downcase(authority) == String.downcase(local_domain())
  end

  defp local_host?(_parsed), do: false

  defp default_port?("https", 443), do: true
  defp default_port?("http", 80), do: true
  defp default_port?(_scheme, _port), do: false

  # The activity wrapper names the same post as the object it wraps. A peer
  # that stored only the wrapper's id and comes back with it is asking about
  # the post, so it resolves to the post rather than to nothing.
  defp match_segments(["users", _username, "statuses", id | rest])
       when rest in [[], ["activity"]],
       do: status_id(id)

  defp match_segments(["ap", "users", _id, "statuses", id | rest])
       when rest in [[], ["activity"]],
       do: status_id(id)

  defp match_segments(["users", username]), do: {:account, username}

  defp match_segments(["ap", "users", id]) do
    case Integer.parse(id) do
      {account_id, ""} -> {:account_id, account_id}
      _ -> :error
    end
  end

  defp match_segments(_segments), do: :error

  defp status_id(id) do
    case Integer.parse(id) do
      {status_id, ""} -> {:status, status_id}
      _ -> :error
    end
  end

  @doc """
  Whether a domain is this server.
  """
  @spec local_domain?(String.t() | nil) :: boolean()
  def local_domain?(nil), do: true
  def local_domain?(domain), do: String.downcase(domain) == String.downcase(local_domain())

  @doc """
  The `user@host` handle for an account, always with the host.

  WebFinger subjects carry the domain even for local accounts, because the
  question being answered is asked by somebody who is not here.
  """
  @spec full_handle(Account.t()) :: String.t()
  def full_handle(%Account{username: username, domain: nil}), do: "#{username}@#{local_domain()}"
  def full_handle(%Account{username: username, domain: domain}), do: "#{username}@#{domain}"
end

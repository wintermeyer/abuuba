defmodule Abuuba.Federation.WebFinger do
  @moduledoc """
  How `user@domain` becomes an actor URI, in both directions.

  WebFinger is the only thing that turns a handle somebody types into an
  address a server can fetch. It is also, and this is the part worth being
  careful about, the whole identity model of the fediverse.

  ## The loopback check

  Anybody can publish an actor document claiming any handle. What makes a claim
  true is that the handle's own domain agrees: `alice@example.org` is whoever
  `example.org`'s WebFinger says it is, and nobody else. So after fetching an
  actor, the handle it claims is looked up at its own domain and the answer has
  to point back at the same actor URI.

  Without that check, a server at `evil.example` can publish an actor claiming
  to be `alice@example.org`, and every server that skips the check will file its
  posts under Alice's handle. The check is cheap and it is the difference
  between a handle meaning something and meaning nothing.

  ## Fetching

  The fetcher is passed in. Resolving a handle means an outbound request to a
  host somebody else chose, which is an SSRF question with its own answer and
  its own issue; this module decides what to ask for and what an answer means.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.URIs

  @activity_json "application/activity+json"

  @doc """
  The JRD document describing a local account.
  """
  @spec jrd(Account.t()) :: map()
  def jrd(%Account{} = account) do
    actor_uri = URIs.actor_uri(account)

    %{
      "subject" => "acct:" <> URIs.full_handle(account),
      "aliases" => Enum.uniq([URIs.profile_url(account), actor_uri]),
      "links" => [
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => URIs.profile_url(account)
        },
        %{"rel" => "self", "type" => @activity_json, "href" => actor_uri},
        %{
          "rel" => "http://ostatus.org/schema/1.0/subscribe",
          "template" => "#{URIs.base_url()}/authorize_interaction?uri={uri}"
        }
      ]
    }
  end

  @doc """
  Splits a WebFinger `resource` into a handle.

  Accepts `acct:user@host`, a bare `user@host`, and the leading `@` people
  paste out of a profile page. Returns `:error` for anything else rather than
  guessing, since a resource we cannot parse is not a resource we host.
  """
  @spec parse_resource(String.t() | nil) :: {:ok, String.t(), String.t()} | :error
  def parse_resource(nil), do: :error

  def parse_resource(resource) when is_binary(resource) do
    resource
    |> String.trim()
    |> String.replace_prefix("acct:", "")
    |> String.replace_prefix("@", "")
    |> String.split("@")
    |> case do
      [username, domain] when username != "" and domain != "" -> {:ok, username, domain}
      _ -> :error
    end
  end

  def parse_resource(_resource), do: :error

  @doc """
  The actor URI a JRD points at, or `:error`.
  """
  @spec self_link(map()) :: {:ok, String.t()} | :error
  def self_link(%{"links" => links}) when is_list(links) do
    links
    |> Enum.find(fn link ->
      link["rel"] == "self" and String.starts_with?(link["type"] || "", @activity_json)
    end)
    |> case do
      %{"href" => href} when is_binary(href) -> {:ok, href}
      _ -> :error
    end
  end

  def self_link(_jrd), do: :error

  @doc """
  Looks up a handle, following the fallbacks the network actually needs.

  Tries `/.well-known/webfinger` first. On a 404 it falls back to the LRDD
  template in `/.well-known/host-meta`, which a handful of older servers still
  rely on. A 410 means the account is gone, which is different from never
  having existed and is reported as such so the caller can tombstone rather
  than retry.

  Exactly one subject redirect is followed. Handles do get redirected, by
  servers that moved a domain, but a chain of them is either a loop or somebody
  walking us somewhere; one hop covers the real case and cannot be turned into
  a walk.
  """
  @spec lookup(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :gone | :malformed | term()}
  def lookup(handle, opts) do
    fetch = Keyword.fetch!(opts, :fetch)
    hops = Keyword.get(opts, :hops, 1)

    with {:ok, username, domain} <- parse_handle(handle) do
      do_lookup(username, domain, fetch, hops)
    end
  end

  defp parse_handle(handle) do
    case parse_resource(handle) do
      {:ok, username, domain} -> {:ok, username, domain}
      :error -> {:error, :malformed}
    end
  end

  defp do_lookup(username, domain, fetch, hops) do
    case fetch.(webfinger_url(domain, username)) do
      {:ok, 200, body} -> interpret(body, username, domain, fetch, hops)
      {:ok, 404, _body} -> via_host_meta(username, domain, fetch, hops)
      {:ok, 410, _body} -> {:error, :gone}
      {:ok, _status, _body} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp interpret(body, username, domain, fetch, hops) do
    with {:ok, jrd} <- decode(body) do
      case redirected_subject(jrd, username, domain) do
        nil ->
          {:ok, jrd}

        {other_user, other_domain} when hops > 0 ->
          do_lookup(other_user, other_domain, fetch, hops - 1)

        _exhausted ->
          # One hop is the real case. More than one is a loop or somebody
          # walking us from host to host, and neither is worth following.
          {:error, :too_many_redirects}
      end
    end
  end

  # A subject naming a different handle is the server saying "this account
  # lives over there".
  defp redirected_subject(jrd, username, domain) do
    with subject when is_binary(subject) <- jrd["subject"],
         {:ok, subject_user, subject_domain} <- parse_resource(subject),
         false <- same_handle?({subject_user, subject_domain}, {username, domain}) do
      {subject_user, subject_domain}
    else
      _ -> nil
    end
  end

  defp same_handle?({a_user, a_domain}, {b_user, b_domain}) do
    String.downcase(a_user) == String.downcase(b_user) and
      String.downcase(a_domain) == String.downcase(b_domain)
  end

  defp via_host_meta(username, domain, fetch, hops) do
    with {:ok, 200, body} <- fetch.(host_meta_url(domain)),
         {:ok, template} <- lrdd_template(body),
         url <-
           String.replace(template, "{uri}", URI.encode_www_form("acct:#{username}@#{domain}")),
         {:ok, 200, jrd_body} <- fetch.(url),
         {:ok, jrd} <- decode(jrd_body) do
      interpret_without_redirect(jrd, username, domain, fetch, hops)
    else
      {:ok, 410, _body} -> {:error, :gone}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp interpret_without_redirect(jrd, username, domain, fetch, hops) do
    case redirected_subject(jrd, username, domain) do
      nil ->
        {:ok, jrd}

      {other_user, other_domain} when hops > 0 ->
        do_lookup(other_user, other_domain, fetch, hops - 1)

      _ ->
        {:error, :too_many_redirects}
    end
  end

  @doc """
  The LRDD template from a host-meta document.
  """
  @spec lrdd_template(String.t()) :: {:ok, String.t()} | :error
  def lrdd_template(xml) when is_binary(xml) do
    case Regex.run(~r/rel=['"]lrdd['"][^>]*template=['"]([^'"]+)['"]/, xml) do
      [_, template] ->
        {:ok, template}

      _ ->
        # Attribute order is not fixed in XML, so try the other way round
        # rather than failing on a document that is perfectly valid.
        case Regex.run(~r/template=['"]([^'"]+)['"][^>]*rel=['"]lrdd['"]/, xml) do
          [_, template] -> {:ok, template}
          _ -> :error
        end
    end
  end

  @doc """
  Confirms that a handle's own domain agrees the actor URI is that handle.

  This is the check the whole identity model rests on. See the module doc.
  """
  @spec verify_loopback(String.t(), String.t(), keyword()) ::
          :ok | {:error, :loopback_mismatch | term()}
  def verify_loopback(handle, actor_uri, opts) do
    with {:ok, _username, domain} <- parse_handle(handle),
         :ok <- check_authority(domain, actor_uri),
         {:ok, jrd} <- lookup(handle, opts),
         {:ok, found} <- self_link_or_error(jrd) do
      if same_uri?(found, actor_uri), do: :ok, else: {:error, :loopback_mismatch}
    end
  end

  # The actor URI has to live on the handle's own domain. Checking the
  # WebFinger answer alone would let example.org hand back an actor URI on
  # another host, which is the same forgery one step removed.
  defp check_authority(domain, actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) ->
        if String.downcase(host) == String.downcase(domain),
          do: :ok,
          else: {:error, :loopback_mismatch}

      _ ->
        {:error, :loopback_mismatch}
    end
  end

  defp self_link_or_error(jrd) do
    case self_link(jrd) do
      {:ok, href} -> {:ok, href}
      :error -> {:error, :malformed}
    end
  end

  # Compared as URIs rather than as strings, so a trailing slash or a different
  # case in the host is not read as a forgery.
  defp same_uri?(a, b) do
    left = URI.parse(a)
    right = URI.parse(b)

    down(left.scheme) == down(right.scheme) and
      down(left.host) == down(right.host) and
      left.port == right.port and
      String.trim_trailing(left.path || "", "/") == String.trim_trailing(right.path || "", "/")
  end

  defp down(nil), do: nil
  defp down(value), do: String.downcase(value)

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = jrd} -> {:ok, jrd}
      _ -> {:error, :malformed}
    end
  end

  defp decode(%{} = jrd), do: {:ok, jrd}
  defp decode(_body), do: {:error, :malformed}

  @doc """
  The WebFinger URL for a handle on a given domain.
  """
  @spec webfinger_url(String.t(), String.t()) :: String.t()
  def webfinger_url(domain, username) do
    resource = URI.encode_www_form("acct:#{username}@#{domain}")

    "https://#{domain}/.well-known/webfinger?resource=#{resource}"
  end

  @doc """
  The host-meta URL for a domain.
  """
  @spec host_meta_url(String.t()) :: String.t()
  def host_meta_url(domain), do: "https://#{domain}/.well-known/host-meta"
end

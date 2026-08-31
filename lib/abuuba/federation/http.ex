defmodule Abuuba.Federation.HTTP do
  @moduledoc """
  The one way abuuba talks to another server.

  Everything outbound goes through here, and that is the design rather than a
  convention: SSRF protection, size caps, deadlines, redirect limits and the
  per-host circuit breaker all live in one place, so a new caller cannot
  accidentally be the one that skipped a check. A second HTTP client anywhere
  in this codebase is a bug.

  ## What it defends against

  * **SSRF.** Every URL fetched came from a stranger. See
    `Abuuba.Federation.HTTP.Address`; the check runs again on every redirect,
    because a public URL that redirects to `169.254.169.254` is exactly how
    that check gets skipped.
  * **Resource exhaustion.** A peer that answers slowly, forever, or with a
    hundred megabytes of JSON costs us a process and a connection either way.
    Deadlines and a size cap bound both.
  * **A peer that is down.** A dead host would otherwise soak up a timeout on
    every one of thousands of queued deliveries. The circuit breaker refuses
    quickly once a host has failed enough times in a row.
  """

  require Logger

  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.HTTP.Address
  alias Abuuba.Federation.HTTP.BodyLimit
  alias Abuuba.Federation.HTTP.CircuitBreaker
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Federation.JSONLD
  alias Abuuba.Federation.Limits
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.URIs
  alias Abuuba.Instance

  # An ActivityPub document is a few kilobytes. A megabyte is generous enough
  # that nothing legitimate hits it and small enough that a hostile peer cannot
  # spend our memory.
  @max_json_bytes Limits.max_document_bytes()

  @connect_timeout 5_000
  @receive_timeout 10_000

  @max_redirects 3

  @browser_accept "text/html,application/xhtml+xml"

  @activity_json "application/activity+json"
  @ld_json "application/ld+json"
  @as2_profile ~s(profile="https://www.w3.org/ns/activitystreams")

  @doc """
  Fetches an ActivityPub document, or lets a caller substitute the fetching.

  `get_json/2` with the `:fetch` option honoured: a test hands in a function
  and everything else goes over the wire. Three resolvers each carried a
  byte-identical copy of this, which is three places to remember when the
  option grows a second shape.
  """
  @spec fetch_json(String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | {:status, integer()}}
  def fetch_json(url, opts \\ []) do
    case Keyword.get(opts, :fetch) do
      nil -> get_json(url, opts)
      fetcher -> fetcher.(url)
    end
  end

  @doc """
  Fetches an ActivityPub document.

  Signed as the instance actor by default, because a growing number of servers
  will not answer an unsigned request. Signing as the server rather than as a
  person keeps a fetch from telling the remote host which of our users was
  looking.
  """
  @spec get_json(String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | {:status, integer()}}
  def get_json(url, opts \\ []) do
    with :ok <- CircuitBreaker.check(host_of(url)),
         {:ok, status, headers, body} <- request(:get, url, nil, opts),
         :ok <- check_status(status),
         :ok <- check_content_type(headers),
         {:ok, document} <- decode(body) do
      answered(url)
      {:ok, document}
    else
      {:error, reason} ->
        record_failure(url, reason)
        {:error, reason}
    end
  end

  @doc """
  Fetches a document as bytes, following redirects, and says where it ended up.

  For everything that is not ActivityPub: an ordinary web page, an oEmbed
  answer, a picture. The final URL comes back because a link that redirects is
  a link to where it landed, and a caller that keyed on what it asked for would
  hold two records for one thing.

  Unsigned by default. A preview card is fetched on behalf of whoever posted
  the link, and signing as the instance actor would tell every site somebody
  links to that this server is the one asking.

  `:max_bytes` raises the ceiling for a caller fetching something that is not a
  document. A photograph truncated to a megabyte is a corrupt file, and one
  written to the cache is a corrupt file served forever.
  """
  @spec get_document(String.t(), keyword()) ::
          {:ok, %{url: String.t(), status: integer(), headers: list(), body: binary()}}
          | {:error, term()}
  def get_document(url, opts \\ []) do
    opts = Keyword.put_new(opts, :sign_as, nil)

    with :ok <- CircuitBreaker.check(host_of(url)),
         {:ok, final_url, status, headers, body} <- request_tracking_url(url, opts),
         :ok <- check_status(status) do
      answered(url)

      {:ok, %{url: final_url, status: status, headers: headers, body: body}}
    else
      {:error, reason} ->
        record_failure(url, reason)
        {:error, reason}
    end
  end

  @doc """
  Fetches JSON that is not an ActivityPub document.

  A REST API — this server's own release feed, another server's list of custom
  emoji — answers `application/json`, which `get_json/2` refuses on purpose:
  that one speaks ActivityPub, and accepting anything that parses would let a
  peer hand it a document it never agreed to read. The refusal was silently
  making a feature impossible rather than noisy, though: the update check asked
  GitHub for the latest release and threw the answer away on every run, for as
  long as the feature has existed.

  Unsigned, like `get_document/2` and for the same reason. Signing tells the
  other end which server is asking, and a public JSON endpoint has no business
  knowing.

  The answer may be an object or an array — `/api/v1/custom_emojis` is a list —
  so this does not narrow it to a map the way `get_json/2` does.
  """
  @spec get_rest_json(String.t(), keyword()) ::
          {:ok, map() | list()} | {:error, atom() | {:status, integer()}}
  def get_rest_json(url, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:sign_as, nil)
      |> Keyword.put_new(:accept, "application/json")

    with :ok <- CircuitBreaker.check(host_of(url)),
         {:ok, status, headers, body} <- request(:get, url, nil, opts),
         :ok <- check_status(status),
         :ok <- check_json_content_type(headers),
         {:ok, document} <- decode_any(body) do
      answered(url)
      {:ok, document}
    else
      {:error, reason} ->
        record_failure(url, reason)
        {:error, reason}
    end
  end

  @doc """
  Asks where a URL points, without going there.

  A redirect is the answer rather than something to follow, so this is the one
  request in here that stops at the first hop: a caller checking that a short
  link resolves to a particular address wants to know where it points, and
  following it would throw away the question. The answer is absolute, resolved
  against the URL that was asked, because a `Location` may be relative and
  every caller would otherwise have to resolve it themselves.

  `{:ok, nil}` means the URL answered with something that is not a redirect.
  Asked with a HEAD and unsigned, like `get_document/2`.
  """
  @spec redirect_hop(String.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def redirect_hop(url, opts \\ []) do
    opts = Keyword.put_new(opts, :sign_as, nil)

    with :ok <- CircuitBreaker.check(host_of(url)),
         {:ok, status, headers, _body} <- perform_checked(:head, url, nil, opts),
         :ok <- check_hop_status(status) do
      answered(url)

      {:ok, URIs.absolute(location(headers), url)}
    else
      {:error, reason} ->
        record_failure(url, reason)
        {:error, reason}
    end
  end

  # A redirect is the answer here, so 3xx joins 2xx as "this host answered".
  # Checked at all because `answered/1` clears both the breaker and the durable
  # "we have given up on this peer": a 500 counting as contact would let anybody
  # who can name a URL reset what this server has learned about a host.
  defp check_hop_status(status) when status in 200..399, do: :ok
  defp check_hop_status(status), do: {:error, {:status, status}}

  @doc """
  Delivers a signed document to a peer's inbox.
  """
  @spec post_json(String.t(), map() | String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def post_json(url, document, opts \\ []) do
    body = if is_binary(document), do: document, else: Jason.encode!(document)

    with :ok <- CircuitBreaker.check(host_of(url)),
         {:ok, status, _headers, response} <- request(:post, url, body, opts) do
      answered(url)
      note_refusal(url, status, response)
      {:ok, status}
    else
      {:error, reason} ->
        record_failure(url, reason)
        {:error, reason}
    end
  end

  # A peer that refuses a delivery says why in the body, and that sentence was
  # being thrown away: an operator saw "refused 401" and had nowhere to look.
  # "The other server would not take it" is one of the two questions anybody
  # running one of these ever asks, and the answer was already on the wire.
  #
  # Only 4xx. A 5xx is the other server having a bad minute and is retried, and
  # its body is a stack trace or an HTML error page.
  defp note_refusal(url, status, response) when status >= 400 and status < 500 do
    Logger.warning("#{host_of(url)} refused a delivery with #{status}: #{summarise(response)}")
  end

  defp note_refusal(_url, _status, _response), do: :ok

  # Enough to name the reason, not enough to put a page of somebody else's
  # markup in the log.
  defp summarise(response) when is_binary(response) do
    response |> String.trim() |> String.slice(0, 200)
  end

  defp summarise(response), do: inspect(response, limit: 5)

  @doc """
  The user agent abuuba sends.

  Names the software, the version and the server, and marks itself a bot. An
  admin reading their access log should be able to tell what we are and who to
  contact without guessing.
  """
  @spec user_agent() :: String.t()
  def user_agent do
    "#{Instance.software_name()}/#{Instance.version()} (+#{URIs.base_url()}; bot)"
  end

  @doc """
  What to ask for when fetching an ordinary web page rather than ActivityPub.

  What a browser sends, because a page served to a crawler is often not the
  page a reader gets, and the markup that matters — the OpenGraph tags, the
  `rel="me"` — lives in the one a reader gets. One value rather than one per
  caller: two fetchers asking differently can be shown different pages by the
  same host, and then one of them finds a link the other cannot.
  """
  @spec browser_accept() :: String.t()
  def browser_accept, do: @browser_accept

  ## The request itself

  # The same hops as `request/5`, keeping hold of the URL each one landed on.
  # Written beside it rather than folded into it, because every existing caller
  # wants the four-element answer and threading a fifth through all of them to
  # serve one caller would be the wrong trade.
  defp request_tracking_url(url, opts, redirects_left \\ @max_redirects) do
    case perform_checked(:get, url, nil, opts) do
      {:ok, status, response_headers, _body} when status in 300..399 ->
        follow_tracking_url(url, opts, response_headers, redirects_left)

      {:ok, status, response_headers, response_body} ->
        {:ok, url, status, response_headers, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One hop, and the only place a request is actually made. The address check
  # and the pinning of the connection to the address it approved are the two
  # halves of the SSRF defence, and they are written once so that a caller
  # cannot be the one that skipped them: a second copy would compile, fetch,
  # and be wrong in a way nothing tests.
  defp perform_checked(method, url, body, opts) do
    with {:ok, addresses} <- Address.checked(url, opts) do
      headers = build_headers(method, url, body, opts)

      perform(method, url, body, headers, [{:addresses, addresses} | opts])
    end
  end

  defp follow_tracking_url(_url, _opts, _headers, 0), do: {:error, :too_many_redirects}

  defp follow_tracking_url(url, opts, headers, redirects_left) do
    case URIs.absolute(location(headers), url) do
      nil -> {:error, :redirect_without_location}
      target -> request_tracking_url(target, opts, redirects_left - 1)
    end
  end

  defp request(method, url, body, opts, redirects_left \\ @max_redirects) do
    case perform_checked(method, url, body, opts) do
      {:ok, status, response_headers, _body} when status in 300..399 ->
        follow(method, url, body, opts, response_headers, redirects_left)

      {:ok, status, response_headers, response_body} ->
        {:ok, status, response_headers, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Re-checked on every hop. A public URL that redirects to a private address
  # is exactly how the SSRF check gets skipped, and it is not a rare shape:
  # plenty of URL shorteners will happily point anywhere.
  defp follow(_method, _url, _body, _opts, _headers, 0), do: {:error, :too_many_redirects}

  defp follow(method, url, body, opts, headers, redirects_left) do
    case URIs.absolute(location(headers), url) do
      nil -> {:error, :redirect_without_location}
      target -> request(method, target, body, opts, redirects_left - 1)
    end
  end

  defp location(headers) do
    headers
    |> Enum.find(fn {name, _value} -> String.downcase(name) == "location" end)
    |> case do
      {_name, value} when is_binary(value) -> value
      {_name, [value | _]} -> value
      _ -> nil
    end
  end

  defp perform(method, url, body, headers, opts) do
    case Keyword.get(opts, :transport) do
      nil ->
        perform_with_req(
          method,
          url,
          body,
          headers,
          Keyword.get(opts, :addresses, []),
          Keyword.get(opts, :max_bytes, @max_json_bytes)
        )

      transport ->
        transport.(method, url, headers, body)
    end
  end

  @doc """
  The request to make, with the connection pinned to an address already checked.

  Checking a name and then connecting to it are two separate resolutions, and
  anybody who controls a DNS record can answer them differently: public for the
  check, `127.0.0.1` for the connection. So the address that was approved is
  the address that is dialled, and the name travels in the `Host` header and in
  the TLS handshake — which is what keeps certificate verification about the
  name rather than about the number.

  Public because it is the piece worth testing on its own: it decides where
  every outbound request in this server actually goes.
  """
  @spec pinned(atom(), String.t(), term(), list(), [tuple()]) :: keyword()
  def pinned(method, url, body, headers, addresses) do
    uri = URI.parse(url)

    case first_usable(addresses) do
      nil ->
        [method: method, url: url, headers: headers, body: body]

      address ->
        [
          method: method,
          url: %{uri | host: literal(address), authority: nil},
          # The name, not the number. Every server that hosts more than one
          # site needs it, and so does the certificate.
          #
          # Only if the caller has not set one. A signed request has: the
          # signature covers `host`, so `Signature.sign/1` returns it among the
          # headers it produced — and adding a second made every signed fetch
          # malformed under RFC 9112. nginx answers 400 to that without reading
          # the rest, which is most of the fediverse refusing every request
          # abuuba signs.
          headers: put_host(headers, host_header(uri)),
          body: body,
          connect_options: [hostname: uri.host]
        ]
    end
  end

  # What the caller set wins, and replaces rather than joins. A delivery is
  # signed by `Abuuba.Federation.DoubleKnock` before it reaches here and hands
  # the signature over as headers; dropping them meant every delivery arrived
  # unsigned, and an inbox that requires a signature — every Mastodon inbox,
  # authorized fetch or not — answered 401 to all of them.
  defp merge_headers(base, []), do: base

  defp merge_headers(base, extra) do
    named = MapSet.new(extra, fn {name, _value} -> String.downcase(name) end)

    Enum.reject(base, fn {name, _value} -> MapSet.member?(named, String.downcase(name)) end) ++
      extra
  end

  # Whichever host header is already there wins: it is the one the signature
  # was computed over, and it is the same value this would have added.
  defp put_host(headers, host) do
    if Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "host" end) do
      headers
    else
      [{"host", host} | headers]
    end
  end

  # The first address the check approved. They were all approved — the check
  # refuses a name that resolves to a mix — so any of them is as good as any
  # other, and taking the first keeps the choice ours rather than the
  # resolver's.
  defp first_usable(addresses) when is_list(addresses), do: List.first(addresses)
  defp first_usable(_none), do: nil

  # An IPv6 address in a URL is bracketed; an IPv4 one is not.
  defp literal(address) when tuple_size(address) == 8 do
    "[" <> to_string(:inet.ntoa(address)) <> "]"
  end

  defp literal(address), do: to_string(:inet.ntoa(address))

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if port in [nil, default_port(scheme)], do: host, else: "#{host}:#{port}"
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_scheme), do: nil

  defp perform_with_req(method, url, body, headers, addresses, max_bytes) do
    pinned = pinned(method, url, body, headers, addresses)

    request =
      Req.new(
        pinned ++
          [
            # No named pool of our own. Req refuses `:finch` together with
            # `:connect_options`, and `pinned/5` needs the second: the
            # connection goes to an address the check approved, so the name for
            # the handshake and the certificate has to be carried separately.
            # Setting both raised on every outbound request this server made —
            # every actor fetch, every preview card, every proxied picture.
            #
            # Req builds and reuses a pool per distinct set of options, which
            # here means one per host, so connections are still reused across
            # deliveries rather than a handshake being paid per activity.
            #
            # Redirects are followed here rather than by Req, so that every hop
            # goes back through the address check.
            redirect: false,
            max_retries: 0,
            receive_timeout: @receive_timeout,
            # No `pool_timeout`: Req wants it under `finch:` now, and anything
            # under that key raises alongside the `connect_options` above. The
            # connect and receive timeouts bound the request either way, and
            # waiting for a pool slot is not what a slow peer costs us.
            # Merged rather than set, because `pinned/5` puts the name to use in
            # the handshake here and a second `connect_options` would replace it
            # — which would leave the certificate being checked against an IP
            # address, or no connection at all.
            connect_options:
              Keyword.merge(
                [timeout: @connect_timeout],
                Keyword.get(pinned, :connect_options, [])
              ),
            decode_body: false,
            # Streamed and stopped at the ceiling rather than read whole and
            # trimmed afterwards. A peer that answers with ten gigabytes is
            # otherwise ten gigabytes this server allocates before deciding it
            # only wanted one megabyte, and the peer does not have to be a peer:
            # a preview card is fetched from whatever address somebody put in a
            # post.
            into: BodyLimit.collect(max_bytes)
          ]
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status, headers: response_headers, body: response_body}} ->
        {:ok, status, Map.to_list(response_headers), cap(response_body, max_bytes)}

      {:error, %{__exception__: true} = error} ->
        {:error, error_reason(error)}
    end
  end

  # Kept for the last chunk, which may still carry the body past the ceiling,
  # and for a transport that hands back something other than a binary.
  #
  # A megabyte is the right ceiling for a document and the wrong one for a
  # photograph, so a caller fetching media says so. Truncating one of those
  # produced a corrupt file that was then cached and served forever, since
  # nothing downstream can tell a short file from a small one.
  defp cap(body, limit) when is_binary(body) and byte_size(body) > limit do
    binary_part(body, 0, limit)
  end

  defp cap(body, _limit) when is_binary(body), do: body
  defp cap(body, _limit), do: to_string(body)

  defp error_reason(%Req.TransportError{reason: reason}), do: reason
  defp error_reason(%{reason: reason}), do: reason
  defp error_reason(_error), do: :request_failed

  ## Headers

  defp build_headers(method, url, body, opts) do
    base = [
      {"user-agent", user_agent()},
      {"accept", Keyword.get(opts, :accept, "#{@activity_json}, #{@ld_json}; #{@as2_profile}")}
    ]

    base = if method == :post, do: [{"content-type", @activity_json} | base], else: base

    base = merge_headers(base, Keyword.get(opts, :headers, []))

    case signing_key(opts) do
      nil ->
        base

      {key_id, private_key} ->
        {:ok, signature_headers} =
          Signature.sign(
            method: method,
            url: url,
            body: body,
            key_id: key_id,
            private_key: private_key
          )

        base ++ signature_headers
    end
  end

  # Signed as the instance actor unless a caller names somebody else. Signing a
  # read as a person would tell the remote server which of our users is looking
  # at them, which is their reading habits handed to a stranger.
  defp signing_key(opts) do
    case Keyword.get(opts, :sign_as, :instance_actor) do
      nil ->
        nil

      :instance_actor ->
        instance_signing_key()

      {key_id, private_key} ->
        {key_id, private_key}
    end
  end

  defp instance_signing_key, do: InstanceActor.signing_key()

  ## Responses

  defp check_status(status) when status in 200..299, do: :ok
  defp check_status(410), do: {:error, :gone}
  defp check_status(404), do: {:error, :not_found}
  defp check_status(status), do: {:error, {:status, status}}

  # A document that is not declared as ActivityPub is not one. Accepting
  # anything JSON-shaped would let a host that merely serves user uploads hand
  # us an actor document somebody uploaded.
  defp check_content_type(headers) do
    value =
      headers
      |> Enum.find_value(fn {name, value} ->
        if String.downcase(name) == "content-type", do: value
      end)
      |> normalise_header_value()

    cond do
      is_nil(value) -> {:error, :missing_content_type}
      String.contains?(value, @activity_json) -> :ok
      String.contains?(value, @ld_json) and String.contains?(value, "activitystreams") -> :ok
      true -> {:error, :wrong_content_type}
    end
  end

  defp normalise_header_value(nil), do: nil
  defp normalise_header_value([value | _]), do: String.downcase(value)
  defp normalise_header_value(value) when is_binary(value), do: String.downcase(value)

  # A fetched document gets the same shape check as a delivered one. An actor
  # whose real content hides under `@graph` reads, through plain map access, as
  # an actor with no inbox and no key, and acting on that is worse than not
  # having fetched it. See `Abuuba.Federation.JSONLD`.
  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = document} -> readable(document)
      _ -> {:error, :malformed_json}
    end
  end

  # No `readable/1`: that guards against another server handing us an
  # ActivityPub document in a shape this one will not read, which is not a
  # question a REST answer can be asked.
  defp decode_any(body) do
    case Jason.decode(body) do
      {:ok, document} when is_map(document) or is_list(document) -> {:ok, document}
      _ -> {:error, :malformed_json}
    end
  end

  # `application/json`, and the ActivityPub types too: an endpoint answering
  # one of those to a request that asked for plain JSON is still answering
  # JSON, and refusing it would be pedantry with a 500 on the end.
  defp check_json_content_type(headers) do
    value =
      headers
      |> Enum.find_value(fn {name, value} ->
        if String.downcase(name) == "content-type", do: value
      end)
      |> normalise_header_value()

    cond do
      is_nil(value) -> {:error, :missing_content_type}
      String.contains?(value, "json") -> :ok
      true -> {:error, :wrong_content_type}
    end
  end

  defp readable(document) do
    if JSONLD.foreign_shape?(document), do: {:error, :unreadable_shape}, else: {:ok, document}
  end

  # A URL with no host never reaches a peer, so it all shares one bucket. It
  # cannot pass the address check either way.
  defp host_of(url), do: URIs.host_of(url) || "unknown"

  # A refusal by our own checks is not the peer's fault and must not count
  # against them: blocking a private address a thousand times would otherwise
  # trip a breaker on a host that never saw a request.
  defp record_failure(_url, reason)
       when reason in [:private_address, :unsupported_scheme, :missing_host, :blocked_port] do
    :ok
  end

  defp record_failure(url, _reason), do: CircuitBreaker.failed(host_of(url))

  # Two opinions about a host, on two timescales, both revised by the same
  # evidence. The circuit breaker is this node's short-term "stop wasting a
  # timeout on it"; `Availability` is the durable "we have given up delivering
  # to this server". A host that answers anything at all contradicts both, so
  # they are cleared together rather than only where somebody remembered to.
  defp answered(url) do
    host = host_of(url)

    CircuitBreaker.succeeded(host)
    Availability.record_success(host)
  end
end

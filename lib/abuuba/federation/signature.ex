defmodule Abuuba.Federation.Signature do
  @moduledoc """
  HTTP signatures, the draft-cavage flavour the fediverse actually runs on.

  Every server-to-server request carries a signature over a handful of headers,
  and that signature is the only thing establishing who sent it. There is no
  transport-level identity here: TLS says the connection reached the host it
  claimed, not that the activity inside came from the actor it names.

  ## What is signed, and why each part

  The signing string is a list of headers, one per line, in the order the
  `Signature` header declares. Three of them carry the weight:

  * `(request-target)` binds the signature to a method and a path, so a
    signature captured on one endpoint cannot be replayed against another;
  * `date` bounds how long a captured request stays usable;
  * `digest` binds it to the body, without which the signature covers the
    envelope and an attacker can replace what is inside it.

  A POST that does not sign `digest` is therefore refused outright rather than
  accepted with a shrug. That is the check that stops a captured, signed
  request from being turned into a different activity.

  ## The request-target quirk

  Some servers build `(request-target)` from the path alone and leave the query
  string out, and others include it. Both are in the wild, so verification is
  attempted twice, once each way, before a signature is called bad. Guessing
  one and rejecting the other means silently failing to federate with half the
  network for reasons nobody can see from the logs.

  ## Time

  Every function that cares about the clock takes a `:now`, so the window can
  be tested from both sides rather than only in whatever hour the suite runs.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.Signature.RFC9421

  # Twelve hours, with an hour of slack for a clock that is wrong in either
  # direction. Tighter would start refusing legitimate traffic from servers
  # whose clocks drift; looser leaves a captured request usable for longer.
  @max_age_seconds 12 * 60 * 60
  @clock_skew_seconds 60 * 60

  @supported_algorithms ~w(rsa-sha256 hs2019)

  @doc """
  Signs an outbound request.

  Returns the headers to add: `Signature`, plus `Digest` and `Date` where they
  were not already given.

      Signature.sign(
        method: :post,
        url: "https://remote.example/inbox",
        body: json,
        key_id: "https://here.example/users/alice#main-key",
        private_key: pem
      )
  """
  @spec sign(keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def sign(opts) do
    method = opts |> Keyword.fetch!(:method) |> to_string() |> String.downcase()
    url = Keyword.fetch!(opts, :url)
    body = Keyword.get(opts, :body)
    key_id = Keyword.fetch!(opts, :key_id)
    private_key = Keyword.fetch!(opts, :private_key)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    uri = URI.parse(url)

    headers =
      [{"host", host_header(uri)}, {"date", http_date(now)}]
      |> maybe_add_digest(body)

    signed_names = ["(request-target)" | Enum.map(headers, &elem(&1, 0))]

    signing_string = build_signing_string(signed_names, request_target(method, uri), headers)

    with {:ok, signature} <- rsa_sign(signing_string, private_key) do
      signature_header =
        ~s(keyId="#{key_id}",algorithm="rsa-sha256",headers="#{Enum.join(signed_names, " ")}",signature="#{signature}")

      {:ok, headers ++ [{"signature", signature_header}]}
    end
  end

  @doc """
  Verifies an inbound request.

  `resolve_key` is given the `keyId` and returns `{:ok, pem}` or `:error`. It is
  a function rather than a hardcoded lookup because resolving a key that is not
  held locally means fetching a remote actor, which is a different concern with
  its own failure modes and its own issue.

      Signature.verify(
        method: :post,
        path: "/inbox",
        query: "",
        headers: conn_headers,
        body: raw_body,
        resolve_key: &resolve/1
      )
  """
  @spec verify(keyword()) ::
          {:ok, String.t()}
          | {:error,
             :missing_signature
             | :malformed_signature
             | :unsupported_algorithm
             | :missing_date
             | :stale_request
             | :missing_host
             | :missing_digest
             | :digest_mismatch
             | :unknown_key
             | :bad_signature}
  def verify(opts) do
    if RFC9421.applies?(Keyword.fetch!(opts, :headers)) do
      RFC9421.verify(rfc9421_opts(opts))
    else
      verify_cavage(opts)
    end
  end

  # `Signature-Input` has no counterpart in the older scheme, so its presence
  # decides which construction this is with no guessing involved.
  defp rfc9421_opts(opts) do
    Keyword.put_new_lazy(opts, :target_uri, fn ->
      scheme = Keyword.get(opts, :scheme, "https")
      host = Keyword.get(opts, :host, "")
      path = Keyword.fetch!(opts, :path)

      case Keyword.get(opts, :query) do
        nil -> "#{scheme}://#{host}#{path}"
        "" -> "#{scheme}://#{host}#{path}"
        query -> "#{scheme}://#{host}#{path}?#{query}"
      end
    end)
  end

  defp verify_cavage(opts) do
    headers = opts |> Keyword.fetch!(:headers) |> normalise_headers()
    method = opts |> Keyword.fetch!(:method) |> to_string() |> String.downcase()
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, parts} <- parse_signature_header(headers),
         :ok <- check_algorithm(parts),
         :ok <- check_required_headers(parts, method),
         :ok <- check_date(headers, parts, now),
         :ok <- check_digest(headers, opts[:body], method),
         {:ok, pem} <- resolve(opts, parts["keyId"]),
         :ok <- check_signature(parts, headers, method, opts, pem) do
      {:ok, parts["keyId"]}
    end
  end

  @doc """
  The `Digest` header value for a body.
  """
  @spec digest(binary()) :: String.t()
  def digest(body) when is_binary(body) do
    "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))
  end

  @doc """
  The key URI for a local account's actor.
  """
  @spec key_id(String.t()) :: String.t()
  def key_id(actor_uri), do: actor_uri <> "#main-key"

  @doc """
  The actor URI a key URI belongs to.
  """
  @spec actor_uri_from_key_id(String.t()) :: String.t()
  def actor_uri_from_key_id(key_id), do: key_id |> String.split("#") |> List.first()

  @doc """
  How old a signed request may be before it is refused.
  """
  def max_age_seconds, do: @max_age_seconds

  ## Signing string

  defp build_signing_string(names, request_target, headers) do
    lookup = Map.new(headers)

    Enum.map_join(names, "\n", fn
      "(request-target)" -> "(request-target): " <> request_target
      name -> "#{name}: #{Map.get(lookup, name, "")}"
    end)
  end

  defp request_target(method, %URI{} = uri) do
    path = uri.path || "/"

    case uri.query do
      nil -> "#{method} #{path}"
      "" -> "#{method} #{path}"
      query -> "#{method} #{path}?#{query}"
    end
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if default_port?(scheme, port), do: host, else: "#{host}:#{port}"
  end

  defp default_port?("https", 443), do: true
  defp default_port?("http", 80), do: true
  defp default_port?(_scheme, nil), do: true
  defp default_port?(_scheme, _port), do: false

  defp maybe_add_digest(headers, nil), do: headers
  defp maybe_add_digest(headers, ""), do: headers
  defp maybe_add_digest(headers, body), do: headers ++ [{"digest", digest(body)}]

  defp http_date(%DateTime{} = at) do
    at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  ## Verification steps

  defp parse_signature_header(headers) do
    case Map.get(headers, "signature") do
      nil ->
        {:error, :missing_signature}

      raw ->
        parts =
          Regex.scan(~r/([a-zA-Z]+)="([^"]*)"/, raw)
          |> Map.new(fn [_, key, value] -> {key, value} end)

        if Map.has_key?(parts, "keyId") and Map.has_key?(parts, "signature") do
          {:ok, Map.put_new(parts, "headers", "date")}
        else
          {:error, :malformed_signature}
        end
    end
  end

  # hs2019 is the later name for the same construction and plenty of servers
  # send it; an absent algorithm is treated as rsa-sha256, which is what the
  # draft says and what the network assumes.
  defp check_algorithm(parts) do
    case Map.get(parts, "algorithm", "rsa-sha256") do
      algorithm when algorithm in @supported_algorithms -> :ok
      _other -> {:error, :unsupported_algorithm}
    end
  end

  # A GET that does not sign `host` could have been captured against one server
  # and replayed against another. A POST that does not sign `digest` leaves the
  # body unprotected, which is the difference between a signature that proves
  # who sent an activity and one that proves only that somebody sent something.
  defp check_required_headers(parts, method) do
    signed = signed_header_names(parts)

    cond do
      not (Enum.member?(signed, "date") or Enum.member?(signed, "(created)")) ->
        {:error, :missing_date}

      method == "post" and not Enum.member?(signed, "digest") ->
        {:error, :missing_digest}

      method != "post" and not Enum.member?(signed, "host") ->
        {:error, :missing_host}

      true ->
        :ok
    end
  end

  defp check_date(headers, parts, now) do
    signed = signed_header_names(parts)

    cond do
      Enum.member?(signed, "date") -> check_http_date(Map.get(headers, "date"), now)
      Enum.member?(signed, "(created)") -> check_created(parts, now)
      true -> {:error, :missing_date}
    end
  end

  defp check_http_date(nil, _now), do: {:error, :missing_date}

  defp check_http_date(value, now) do
    case parse_http_date(value) do
      {:ok, sent_at} -> within_window(sent_at, now)
      :error -> {:error, :missing_date}
    end
  end

  defp check_created(parts, now) do
    with created when is_binary(created) <- Map.get(parts, "created"),
         {seconds, ""} <- Integer.parse(created),
         {:ok, sent_at} <- DateTime.from_unix(seconds) do
      within_window(sent_at, now)
    else
      _ -> {:error, :missing_date}
    end
  end

  # RFC 7231 preferred form, which is what every server sends. The obsolete
  # RFC 850 and asctime forms are not accepted: nothing on the fediverse emits
  # them, and parsing a two-digit year would mean guessing a century.
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp parse_http_date(value) when is_binary(value) do
    with [_weekday, day, month, year, time, _zone] <- String.split(value, [" ", ", "], trim: true),
         month_number when not is_nil(month_number) <- month_index(month),
         [hour, minute, second] <- String.split(time, ":"),
         {:ok, date} <- Date.new(to_int(year), month_number, to_int(day)),
         {:ok, time} <- Time.new(to_int(hour), to_int(minute), to_int(second)) do
      DateTime.new(date, time, "Etc/UTC")
    else
      _ -> :error
    end
  end

  defp parse_http_date(_value), do: :error

  defp month_index(month), do: Enum.find_index(@months, &(&1 == month)) |> then(&(&1 && &1 + 1))

  defp to_int(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp within_window(sent_at, now) do
    age = DateTime.diff(now, sent_at, :second)

    cond do
      age > @max_age_seconds -> {:error, :stale_request}
      age < -@clock_skew_seconds -> {:error, :stale_request}
      true -> :ok
    end
  end

  defp check_digest(_headers, _body, method) when method != "post", do: :ok

  defp check_digest(headers, body, _method) do
    case Map.get(headers, "digest") do
      nil ->
        {:error, :missing_digest}

      sent ->
        if digest_matches?(sent, body || ""), do: :ok, else: {:error, :digest_mismatch}
    end
  end

  @doc """
  Whether a `Digest` header value covers this body.

  RFC 3230 allows several digests in one header, so ours has to be among them
  rather than be the first. Comparing only the first would let a peer lead with
  a digest in an algorithm we do not compute and hide a mismatch behind it.
  """
  @spec digest_matches?(String.t(), binary()) :: boolean()
  def digest_matches?(header, body) do
    expected = digest(body)

    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.member?(expected)
  end

  defp resolve(opts, key_id) do
    resolver = Keyword.fetch!(opts, :resolve_key)

    case resolver.(key_id) do
      {:ok, pem} -> {:ok, pem}
      _ -> {:error, :unknown_key}
    end
  end

  # Both spellings of (request-target), because both are in the wild. Trying
  # only one silently fails to federate with everybody who chose the other.
  defp check_signature(parts, headers, method, opts, pem) do
    names = signed_header_names(parts)
    path = Keyword.fetch!(opts, :path)
    query = Keyword.get(opts, :query)

    candidates =
      [request_target_string(method, path, query), request_target_string(method, path, nil)]
      |> Enum.uniq()

    signature = Map.get(parts, "signature", "")

    verified? =
      Enum.any?(candidates, fn target ->
        names
        |> build_signing_string(target, Map.to_list(headers))
        |> rsa_verify(signature, pem)
      end)

    if verified?, do: :ok, else: {:error, :bad_signature}
  end

  defp request_target_string(method, path, query) when query in [nil, ""],
    do: "#{method} #{path}"

  defp request_target_string(method, path, query), do: "#{method} #{path}?#{query}"

  defp signed_header_names(parts) do
    parts |> Map.get("headers", "date") |> String.downcase() |> String.split(" ", trim: true)
  end

  defp normalise_headers(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  ## Crypto

  defp rsa_sign(signing_string, pem) do
    with {:ok, key} <- decode_private_key(pem) do
      {:ok,
       signing_string
       |> :public_key.sign(:sha256, key)
       |> Base.encode64()}
    end
  end

  defp rsa_verify(signing_string, signature, pem) do
    with {:ok, decoded} <- Base.decode64(signature),
         {:ok, key} <- decode_public_key(pem) do
      :public_key.verify(signing_string, :sha256, decoded, key)
    else
      _ -> false
    end
  end

  defp decode_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, :bad_key}
    end
  rescue
    _ -> {:error, :bad_key}
  end

  defp decode_public_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, :bad_key}
    end
  rescue
    _ -> {:error, :bad_key}
  end

  @doc """
  Resolves a key from what this server already holds, and nothing else.

  Fetching an actor we have never seen is a different concern with its own
  failure modes, so it plugs in here rather than being buried in verification.
  """
  @spec local_key_resolver() :: (String.t() -> {:ok, String.t()} | :error)
  def local_key_resolver do
    fn key_id ->
      case key_by_id(key_id) do
        {:ok, pem} -> {:ok, pem}
        :error -> key_id |> actor_uri_from_key_id() |> stored_public_key()
      end
    end
  end

  @doc """
  The public key of an account we already hold, by the account rather than by
  the id its key goes under.

  For a caller that has just resolved the actor: deriving the account back out
  of the key id would ask the same wrong question that made the resolution
  necessary.
  """
  @spec public_key_of(Account.t()) :: {:ok, String.t()} | :error
  def public_key_of(%Account{id: account_id}) do
    account_id |> live_keypair() |> public_key_pem()
  end

  # By the string the peer signs with. Stored as they wrote it, so a key id
  # that is a path, a fragment, or neither is found the same way.
  defp key_by_id(key_id) do
    import Ecto.Query

    Keypair
    |> where([k], k.key_id == ^key_id and is_nil(k.revoked_at))
    |> Abuuba.Repo.one()
    |> public_key_pem()
  end

  # The older answer, and still the answer for our own keys and for any peer
  # whose key we stored before its id was kept. It reads the actor out of the
  # key id, which is right whenever the id is the actor's uri plus a fragment
  # and wrong whenever it is anything else -- which is why it is second now
  # rather than only.
  defp stored_public_key(actor_uri) do
    case Abuuba.Repo.get_by(Abuuba.Accounts.Account, uri: actor_uri) do
      nil -> :error
      account -> account.id |> live_keypair() |> public_key_pem()
    end
  end

  defp public_key_pem(%Keypair{public_key: pem}), do: {:ok, pem}
  defp public_key_pem(_keypair), do: :error

  # Any unrevoked key for the account, private half or not: for a remote actor
  # we hold only the public half, and that is exactly what verification needs.
  defp live_keypair(account_id) do
    import Ecto.Query

    Keypair
    |> where([k], k.account_id == ^account_id and is_nil(k.revoked_at))
    |> order_by([k], desc: k.id)
    |> limit(1)
    |> Abuuba.Repo.one()
  end
end

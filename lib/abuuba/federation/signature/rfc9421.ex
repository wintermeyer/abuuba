defmodule Abuuba.Federation.Signature.RFC9421 do
  @moduledoc """
  RFC 9421 message signatures, the standardised successor to draft-cavage.

  Not a variant of the older scheme but a different construction, which is why
  it lives in its own module rather than as a branch inside the other one. Two
  differences matter:

  * the covered components are named rather than positional, and include
    derived ones written with a leading `@` (`@method`, `@target-uri`) that are
    computed from the request rather than read from a header;
  * the parameters that describe the signature (which components, when, whose
    key) are themselves the last line of the signed data, under
    `@signature-params`. A peer therefore cannot re-describe a captured
    signature as covering something else, which in the older scheme was only
    prevented by the header list happening to be inside the string.

  The body is bound through `Content-Digest` (RFC 9530) rather than `Digest`,
  and only `sha-256` is accepted. The older `Digest` header allowed a peer to
  pick the algorithm, and accepting a weak one is the same as accepting none.

  ## Dispatch

  A request is RFC 9421 exactly when it carries `Signature-Input`. That header
  has no counterpart in the older scheme, so its presence is unambiguous and no
  guessing is involved.
  """

  # Mastodon signs with RSASSA-PKCS1-v1_5 over SHA-256, which is what OTP's
  # :public_key produces for an RSA key. Anything else is refused rather than
  # attempted: a signature we cannot check is not a signature we should accept.
  @supported_algorithms ~w(rsa-v1_5-sha256)

  @max_age_seconds 12 * 60 * 60
  @clock_skew_seconds 60 * 60

  @label "sig1"

  @doc """
  Signs an outbound request.

  Returns the headers to add: `Signature-Input`, `Signature`, and
  `Content-Digest` where there is a body.
  """
  @spec sign(keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def sign(opts) do
    method = opts |> Keyword.fetch!(:method) |> to_string() |> String.upcase()
    url = Keyword.fetch!(opts, :url)
    body = Keyword.get(opts, :body)
    key_id = Keyword.fetch!(opts, :key_id)
    private_key = Keyword.fetch!(opts, :private_key)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    digest_header = body && content_digest(body)
    components = covered_components(digest_header)

    params = signature_params(components, now, key_id)
    values = component_values(method, url, digest_header)
    base = signature_base(components, values, params)

    with {:ok, signature} <- rsa_sign(base, private_key) do
      headers =
        [
          {"signature-input", "#{@label}=#{params}"},
          {"signature", "#{@label}=:#{signature}:"}
        ]

      {:ok, maybe_digest_header(headers, digest_header)}
    end
  end

  @doc """
  Verifies an inbound RFC 9421 request.
  """
  @spec verify(keyword()) :: {:ok, String.t()} | {:error, atom()}
  def verify(opts) do
    headers = opts |> Keyword.fetch!(:headers) |> normalise_headers()
    method = opts |> Keyword.fetch!(:method) |> to_string() |> String.upcase()
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, params_string, components, params} <- parse_signature_input(headers),
         {:ok, signature} <- parse_signature(headers),
         :ok <- check_algorithm(params),
         :ok <- check_required_components(components, method),
         :ok <- check_created(params, now),
         :ok <- check_content_digest(headers, opts[:body], method),
         {:ok, pem} <- resolve(opts, params["keyid"]),
         :ok <- check_signature(components, params_string, signature, opts, method, headers, pem) do
      {:ok, params["keyid"]}
    end
  end

  @doc """
  The `Content-Digest` header value for a body.
  """
  @spec content_digest(binary()) :: String.t()
  def content_digest(body) when is_binary(body) do
    "sha-256=:" <> Base.encode64(:crypto.hash(:sha256, body)) <> ":"
  end

  @doc """
  Whether a request is signed the RFC 9421 way.
  """
  @spec applies?(list() | map()) :: boolean()
  def applies?(headers) do
    headers |> normalise_headers() |> Map.has_key?("signature-input")
  end

  ## Building

  defp covered_components(nil), do: ~w("@method" "@target-uri")
  defp covered_components(_digest), do: ~w("@method" "@target-uri" "content-digest")

  defp signature_params(components, now, key_id) do
    "(#{Enum.join(components, " ")});created=#{DateTime.to_unix(now)};keyid=\"#{key_id}\";alg=\"rsa-v1_5-sha256\""
  end

  defp component_values(method, url, digest_header) do
    %{
      ~s("@method") => method,
      ~s("@target-uri") => url,
      ~s("content-digest") => digest_header
    }
  end

  # The parameters are the final line of what gets signed, so a peer cannot
  # take a valid signature and re-describe it as covering different components.
  defp signature_base(components, values, params) do
    lines = Enum.map(components, fn name -> "#{name}: #{Map.get(values, name, "")}" end)

    Enum.join(lines ++ [~s("@signature-params": ) <> params], "\n")
  end

  defp maybe_digest_header(headers, nil), do: headers
  defp maybe_digest_header(headers, digest), do: [{"content-digest", digest} | headers]

  ## Parsing

  defp parse_signature_input(headers) do
    case Map.get(headers, "signature-input") do
      nil ->
        {:error, :missing_signature}

      raw ->
        with [_, params_string] <- Regex.run(~r/^[^=]+=(\(.*)$/, String.trim(raw)),
             [_, component_list] <- Regex.run(~r/^\(([^)]*)\)/, params_string) do
          components =
            component_list
            |> String.split(" ", trim: true)
            |> Enum.map(&String.trim/1)

          {:ok, params_string, components, parse_params(params_string)}
        else
          _ -> {:error, :malformed_signature}
        end
    end
  end

  defp parse_params(params_string) do
    quoted = Regex.scan(~r/;\s*([a-zA-Z]+)="([^"]*)"/, params_string)
    bare = Regex.scan(~r/;\s*([a-zA-Z]+)=([^;"\s]+)/, params_string)

    Map.new(quoted ++ bare, fn [_, key, value] -> {key, value} end)
  end

  defp parse_signature(headers) do
    case Map.get(headers, "signature") do
      nil ->
        {:error, :missing_signature}

      raw ->
        case Regex.run(~r/:([^:]+):/, raw) do
          [_, encoded] -> {:ok, encoded}
          _ -> {:error, :malformed_signature}
        end
    end
  end

  ## Checks

  defp check_algorithm(params) do
    case Map.get(params, "alg") do
      nil -> :ok
      algorithm when algorithm in @supported_algorithms -> :ok
      _other -> {:error, :unsupported_algorithm}
    end
  end

  defp check_required_components(components, method) do
    cond do
      ~s("@method") not in components -> {:error, :missing_method}
      ~s("@target-uri") not in components -> {:error, :missing_target}
      method == "POST" and ~s("content-digest") not in components -> {:error, :missing_digest}
      true -> :ok
    end
  end

  # `created` is a parameter here rather than a Date header, so there is no
  # separate clock to disagree with.
  defp check_created(params, now) do
    with created when is_binary(created) <- Map.get(params, "created"),
         {seconds, ""} <- Integer.parse(created),
         {:ok, sent_at} <- DateTime.from_unix(seconds) do
      age = DateTime.diff(now, sent_at, :second)

      cond do
        age > @max_age_seconds -> {:error, :stale_request}
        age < -@clock_skew_seconds -> {:error, :stale_request}
        true -> :ok
      end
    else
      _ -> {:error, :missing_date}
    end
  end

  defp check_content_digest(_headers, _body, method) when method != "POST", do: :ok

  defp check_content_digest(headers, body, _method) do
    case Map.get(headers, "content-digest") do
      nil ->
        {:error, :missing_digest}

      sent ->
        expected = content_digest(body || "")

        # Only sha-256 is computed, and a peer offering only something else has
        # not bound its body to anything we can check.
        if sent |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.member?(expected) do
          :ok
        else
          {:error, :digest_mismatch}
        end
    end
  end

  defp resolve(opts, key_id) do
    resolver = Keyword.fetch!(opts, :resolve_key)

    case key_id && resolver.(key_id) do
      {:ok, pem} -> {:ok, pem}
      _ -> {:error, :unknown_key}
    end
  end

  defp check_signature(components, params_string, signature, opts, method, headers, pem) do
    values = %{
      ~s("@method") => method,
      ~s("@target-uri") => Keyword.fetch!(opts, :target_uri),
      ~s("@authority") => Keyword.get(opts, :authority, ""),
      ~s("content-digest") => Map.get(headers, "content-digest", "")
    }

    base = signature_base(components, values, params_string)

    if rsa_verify(base, signature, pem), do: :ok, else: {:error, :bad_signature}
  end

  ## Crypto

  defp rsa_sign(base, pem) do
    with {:ok, key} <- decode_key(pem) do
      {:ok, base |> :public_key.sign(:sha256, key) |> Base.encode64()}
    end
  end

  defp rsa_verify(base, signature, pem) do
    with {:ok, decoded} <- Base.decode64(signature),
         {:ok, key} <- decode_key(pem) do
      :public_key.verify(base, :sha256, decoded, key)
    else
      _ -> false
    end
  end

  defp decode_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, :bad_key}
    end
  rescue
    _ -> {:error, :bad_key}
  end

  defp normalise_headers(headers) when is_map(headers), do: headers

  defp normalise_headers(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
  end
end

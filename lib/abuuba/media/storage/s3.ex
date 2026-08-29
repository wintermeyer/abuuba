defmodule Abuuba.Media.Storage.S3 do
  @moduledoc """
  Objects in an S3-compatible bucket.

  Signed here rather than through an SDK. The whole of what this server needs
  is PUT, DELETE and HEAD on one bucket, and a signing function is a hundred
  lines where an SDK is a dependency tree with its own HTTP client, its own
  configuration and its own opinions about credentials. `Abuuba.Media.Storage.S3`
  works against AWS and against everything that speaks the same protocol, which
  is what most people running a fediverse server actually use.

  ## Every object is immutable

  The name contains random bytes and the id is never reused, so an object at a
  key is the same bytes forever. `cache-control: immutable` says so, and it is
  the difference between a CDN that serves a picture once from the bucket and
  one that revalidates it on every reader's timeline.

  ## A failure is a failure

  A non-2xx answer is returned as an error rather than logged and stepped over.
  Carrying on would leave an attachment pointing at an object that was never
  written, which shows up much later as a picture that has never existed.
  """

  @behaviour Abuuba.Media.Storage

  alias Abuuba.Media.Storage

  @service "s3"
  @cache_control "public, max-age=31536000, immutable"

  @impl Storage
  def put(key, source_path, opts) do
    with {:ok, body} <- File.read(source_path) do
      request(:put, key, body, put_headers(source_path), opts)
    end
  end

  @impl Storage
  def delete(key) do
    request(:delete, key, "", %{}, [])

    :ok
  end

  @impl Storage
  def exists?(key) do
    case request(:head, key, "", %{}, []) do
      :ok -> true
      _ -> false
    end
  end

  @impl Storage
  def url(key) do
    # Encoded, because this is the address a browser is handed rather than one
    # this server resolves: a key with a space in it is not a URL.
    encoded = encoded_path(key)

    case Storage.alias_host() do
      nil -> "#{endpoint()}/#{encoded}"
      host -> "#{host}/#{encoded}"
    end
  end

  # Nothing here is on this machine's disk, which is what the pipeline has to
  # know before reaching for a file with a local tool.
  @impl Storage
  def local_path(_key), do: nil

  @doc """
  Whether this server is configured to talk to a bucket at all.
  """
  @spec configured?() :: boolean()
  def configured? do
    config = config()

    Enum.all?([:bucket, :access_key_id, :secret_access_key], &(config[&1] not in [nil, ""]))
  end

  ## Inside

  defp put_headers(source_path) do
    %{
      "cache-control" => @cache_control,
      "content-type" => MIME.from_path(source_path)
    }
  end

  defp request(method, key, body, headers, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    # Encoded once, then used for both the address and the signature, so the
    # path signed is the path sent however odd a key is. Keys this server
    # generates are hex and an extension, but the importer copies the tree of
    # an existing Mastodon instance and those names are somebody else's.
    uri = URI.parse("#{endpoint()}/#{key}")
    uri = %{uri | path: encoded_path(uri.path)}
    url = URI.to_string(uri)

    signed = sign(method, uri, body, headers, now)

    transport = Keyword.get(opts, :transport, &send_request/1)

    case transport.(%{method: method, url: url, headers: signed, body: body}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp send_request(%{method: method, url: url, headers: headers, body: body}) do
    Req.request(method: method, url: url, headers: headers, body: body, retry: false)
  end

  ## Signature Version 4

  # The algorithm in one place, so the parts that have to agree with each other
  # (the signed header list, their order, the canonical request and the string
  # to sign) cannot drift apart across call sites.
  defp sign(method, %URI{} = uri, body, headers, now) do
    config = config()
    payload_hash = hex(:crypto.hash(:sha256, body))
    stamp = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = Calendar.strftime(now, "%Y%m%d")

    headers =
      headers
      |> Map.merge(%{
        "host" => uri.host,
        "x-amz-content-sha256" => payload_hash,
        "x-amz-date" => stamp
      })
      |> Map.new(fn {name, value} -> {String.downcase(name), to_string(value)} end)

    signed_names = headers |> Map.keys() |> Enum.sort()

    canonical_request =
      Enum.join(
        [
          method |> to_string() |> String.upcase(),
          uri.path,
          "",
          Enum.map_join(signed_names, "", &"#{&1}:#{String.trim(headers[&1])}\n"),
          Enum.join(signed_names, ";"),
          payload_hash
        ],
        "\n"
      )

    scope = "#{date}/#{config[:region]}/#{@service}/aws4_request"

    string_to_sign =
      Enum.join(
        [
          "AWS4-HMAC-SHA256",
          stamp,
          scope,
          hex(:crypto.hash(:sha256, canonical_request))
        ],
        "\n"
      )

    signature = hex(:crypto.mac(:hmac, :sha256, signing_key(config, date), string_to_sign))

    Map.put(
      headers,
      "authorization",
      "AWS4-HMAC-SHA256 Credential=#{config[:access_key_id]}/#{scope}, " <>
        "SignedHeaders=#{Enum.join(signed_names, ";")}, Signature=#{signature}"
    )
  end

  defp signing_key(config, date) do
    "AWS4#{config[:secret_access_key]}"
    |> then(&:crypto.mac(:hmac, :sha256, &1, date))
    |> then(&:crypto.mac(:hmac, :sha256, &1, config[:region]))
    |> then(&:crypto.mac(:hmac, :sha256, &1, @service))
    |> then(&:crypto.mac(:hmac, :sha256, &1, "aws4_request"))
  end

  # The path of the request being sent, not one rebuilt from the key. The two
  # are the same only on AWS, where the bucket is part of the host; every
  # S3-compatible endpoint puts the bucket in the path instead, and signing
  # without it is a signature over a request nobody made. A real bucket
  # answers 403 SignatureDoesNotMatch and names the resource it signed.
  #
  # The leading empty segment is what carries the leading slash.
  defp encoded_path(nil), do: "/"
  defp encoded_path(path), do: Storage.encode_key(path)

  defp hex(binary), do: Base.encode16(binary, case: :lower)

  defp endpoint do
    config = config()

    case config[:endpoint] do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        "#{String.trim_trailing(endpoint, "/")}/#{config[:bucket]}"

      _ ->
        "https://#{config[:bucket]}.s3.#{config[:region]}.amazonaws.com"
    end
  end

  defp config do
    defaults = [region: "us-east-1"]

    Keyword.merge(defaults, Application.get_env(:abuuba, __MODULE__, []))
  end
end

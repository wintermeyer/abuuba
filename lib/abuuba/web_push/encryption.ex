defmodule Abuuba.WebPush.Encryption do
  @moduledoc """
  Encrypting a push payload so that only the browser can read it.

  RFC 8291. The push service in the middle is somebody else's server, usually
  Google's or Mozilla's, and it forwards a message it must not be able to
  read. That is the whole reason this exists rather than sending JSON: without
  it, a notification saying who mentioned somebody and what they said would be
  readable by whoever runs the push service.

  ## How it works

  A fresh keypair per message, agreed against the subscriber's public key by
  ECDH. The shared secret plus the subscriber's auth secret go through HKDF to
  produce a content key and a nonce, and the payload is sealed with AES-128-GCM
  under them. The ephemeral public key travels in the body, so the browser can
  do the same agreement and nobody who only saw the ciphertext can.

  ## Two encodings

  `aes128gcm` is the standard and carries its own header. `aesgcm` is what
  subscriptions made before RFC 8291 use, and it puts the salt and the key in
  HTTP headers instead. Both are here because a browser does not re-subscribe
  just because a standard was finished; the old ones keep working until it
  renews them on its own.
  """

  @curve :prime256v1
  @auth_info "WebPush: info" <> <<0>>

  @doc """
  Seals a payload for one subscriber.

  Returns the body to send and the headers that describe it.
  """
  @spec encrypt(binary(), String.t(), String.t(), String.t()) ::
          {:ok, %{body: binary(), headers: [{String.t(), String.t()}]}} | {:error, atom()}
  def encrypt(payload, p256dh, auth, encoding \\ "aes128gcm") do
    with {:ok, client_public} <- decode(p256dh),
         {:ok, auth_secret} <- decode(auth) do
      {server_public, server_private} = :crypto.generate_key(:ecdh, @curve)
      shared = :crypto.compute_key(:ecdh, client_public, server_private, @curve)
      salt = :crypto.strong_rand_bytes(16)

      seal(encoding, payload, shared, auth_secret, salt, client_public, server_public)
    end
  end

  defp seal("aes128gcm", payload, shared, auth_secret, salt, client_public, server_public) do
    prk = hkdf(auth_secret, shared, key_info(client_public, server_public), 32)
    content_key = hkdf(salt, prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf(salt, prk, "Content-Encoding: nonce" <> <<0>>, 12)

    # The padding delimiter, which is what tells the browser where the payload
    # ends. Without it the browser reads trailing zeroes as content.
    plaintext = payload <> <<2>>

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, content_key, nonce, plaintext, "", true)

    # The standard encoding carries its own header: salt, record size, and the
    # ephemeral key. Nothing about the message lives in an HTTP header, which
    # is what makes it work through a proxy that rewrites them.
    header =
      salt <>
        <<4096::unsigned-big-integer-size(32)>> <> <<byte_size(server_public)>> <> server_public

    {:ok,
     %{
       body: header <> ciphertext <> tag,
       headers: [{"content-encoding", "aes128gcm"}]
     }}
  end

  defp seal("aesgcm", payload, shared, auth_secret, salt, client_public, server_public) do
    prk = hkdf(auth_secret, shared, @auth_info, 32)

    context =
      "P-256" <>
        <<0>> <>
        <<byte_size(client_public)::unsigned-big-integer-size(16)>> <>
        client_public <>
        <<byte_size(server_public)::unsigned-big-integer-size(16)>> <> server_public

    content_key = hkdf(salt, prk, "Content-Encoding: aesgcm" <> <<0>> <> context, 16)
    nonce = hkdf(salt, prk, "Content-Encoding: nonce" <> <<0>> <> context, 12)

    # Two bytes of declared padding, which this encoding requires even when
    # there is none.
    plaintext = <<0, 0>> <> payload

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, content_key, nonce, plaintext, "", true)

    {:ok,
     %{
       body: ciphertext <> tag,
       headers: [
         {"content-encoding", "aesgcm"},
         {"encryption", "salt=" <> url_encode(salt)},
         {"crypto-key", "dh=" <> url_encode(server_public)}
       ]
     }}
  end

  defp seal(_encoding, _payload, _shared, _auth, _salt, _client, _server) do
    {:error, :unsupported_encoding}
  end

  @doc """
  HKDF, which is the one primitive both encodings agree on.
  """
  @spec hkdf(binary(), binary(), binary(), pos_integer()) :: binary()
  def hkdf(salt, input, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, input)

    :hmac
    |> :crypto.mac(:sha256, prk, info <> <<1>>)
    |> binary_part(0, length)
  end

  @doc """
  Base64url without padding, which is what every field in this protocol uses.
  """
  @spec url_encode(binary()) :: String.t()
  def url_encode(value), do: Base.url_encode64(value, padding: false)

  @doc """
  The reverse, tolerating the padding some clients send anyway.
  """
  @spec decode(String.t() | nil) :: {:ok, binary()} | {:error, :invalid_key}
  def decode(nil), do: {:error, :invalid_key}

  def decode(value) when is_binary(value) do
    value
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> pad()
    |> Base.decode64()
    |> case do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_key}
    end
  end

  def decode(_value), do: {:error, :invalid_key}

  defp pad(value) do
    case rem(byte_size(value), 4) do
      0 -> value
      remainder -> value <> String.duplicate("=", 4 - remainder)
    end
  end

  defp key_info(client_public, server_public) do
    "WebPush: info" <> <<0>> <> client_public <> server_public
  end
end

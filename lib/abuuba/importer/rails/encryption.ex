defmodule Abuuba.Importer.Rails.Encryption do
  @moduledoc """
  Reading values Rails encrypted, so they can be re-encrypted with ours.

  Mastodon keeps actor private keys and two-factor secrets in columns declared
  `encrypts`, which is Active Record Encryption: an AES-256-GCM envelope whose
  key is derived from the three `ACTIVE_RECORD_ENCRYPTION_*` variables. Without
  reading them, an import copies the ciphertext and every imported account is
  one whose signatures no longer verify and whose second factor no longer
  works.

  ## The envelope

      {"p": "<base64 ciphertext>", "h": {"iv": "<base64>", "at": "<base64 tag>", "c": true}}

  Anything over about 140 bytes is deflated before it is encrypted, and `c`
  says so. A private key is well over that, so almost every value that matters
  here is compressed and a decryptor that ignores the flag returns plausible
  binary rubbish for exactly the rows it must not.

  ## The key

  PBKDF2-HMAC-SHA1 over the primary key, salted with the key derivation salt,
  65,536 iterations, 32 bytes. Newer Rails can derive with SHA-256 instead, and
  Mastodon turns SHA-1 support on explicitly, so both are tried: the GCM tag
  says which one was right, and a value that verifies under neither is an
  error rather than a guess.

  Everything here was checked against ciphertext produced by Active Record
  itself rather than against a description of the format.
  """

  @iterations 65_536
  @key_bytes 32

  @doc """
  Decrypts one Active Record Encryption value.

  Takes keys that have already been derived, from `keys/2`. Deriving them is
  65,536 rounds of PBKDF2 and the inputs never change, so an import that
  derived per row would spend hours recomputing the same thirty-two bytes.

  `{:ok, plaintext}`, or an error. Never a partial answer: the tag either
  verifies or the value was not encrypted with these keys, and a private key
  decrypted with the wrong one is bytes that look like a key and sign nothing.
  """
  @spec decrypt(String.t() | nil, [binary()]) :: {:ok, String.t()} | {:error, atom()}
  def decrypt(nil, _keys), do: {:error, :missing}
  def decrypt("", _keys), do: {:error, :missing}

  def decrypt(envelope, keys) do
    with {:ok, %{ciphertext: ciphertext, iv: iv, tag: tag, compressed: compressed}} <-
           parse(envelope) do
      Enum.find_value(
        keys,
        {:error, :cannot_decrypt},
        &opened(&1, iv, ciphertext, tag, compressed)
      )
    end
  end

  defp opened(key, iv, ciphertext, tag, compressed) do
    case open(key, iv, ciphertext, tag) do
      plaintext when is_binary(plaintext) -> inflate(plaintext, compressed)
      _no -> nil
    end
  end

  defp inflate(plaintext, false), do: {:ok, plaintext}

  defp inflate(plaintext, true) do
    {:ok, :zlib.uncompress(plaintext)}
  rescue
    _not_deflated -> nil
  end

  @doc """
  Whether a string looks like one of these envelopes at all.

  Used to tell an encrypted column from a plaintext one, because Mastodon has
  both: the legacy `accounts.private_key` is a bare PEM and the newer
  `keypairs.private_key` is encrypted.
  """
  @spec encrypted?(String.t() | nil) :: boolean()
  def encrypted?(value) when is_binary(value), do: match?({:ok, _parsed}, parse(value))
  def encrypted?(_value), do: false

  @doc """
  The keys a source's values were encrypted with, derived once.

  Both digests, because a value that will not verify under one has to be tried
  under the other, and the tag is what says which was right. SHA-1 comes first:
  it is what Mastodon's own configuration turns on, so it is the one that will
  verify on nearly every row.
  """
  @spec keys(String.t(), String.t()) :: [binary()]
  def keys(primary_key, salt) do
    Enum.map([:sha, :sha256], &derive(primary_key, salt, &1))
  end

  @doc """
  One derived key, for a caller checking its configuration by hand.
  """
  @spec derive(String.t(), String.t(), atom()) :: binary()
  def derive(primary_key, salt, digest \\ :sha) do
    :crypto.pbkdf2_hmac(digest, primary_key, salt, @iterations, @key_bytes)
  end

  ## Inside

  defp parse(envelope) do
    with {:ok, %{"p" => payload, "h" => headers}} <- Jason.decode(envelope),
         {:ok, ciphertext} <- Base.decode64(payload),
         {:ok, iv} <- Base.decode64(headers["iv"] || ""),
         {:ok, tag} <- Base.decode64(headers["at"] || "") do
      {:ok, %{ciphertext: ciphertext, iv: iv, tag: tag, compressed: headers["c"] == true}}
    else
      _ -> {:error, :not_an_envelope}
    end
  end

  defp open(key, iv, ciphertext, tag) do
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false)
  rescue
    _ -> nil
  end
end

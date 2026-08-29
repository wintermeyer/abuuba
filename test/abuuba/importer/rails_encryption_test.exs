defmodule Abuuba.Importer.Rails.EncryptionTest do
  use ExUnit.Case, async: true

  alias Abuuba.Importer.Rails.Encryption

  # Produced by Active Record itself, not from a description of the format. A
  # fixture written from the documentation would only prove that this code
  # matches the documentation, which is not the thing that has to be true.
  @primary "test_primary_key_0123456789abcdef"
  @salt "test_key_derivation_salt_00000000"
  @plain "-----BEGIN RSA PRIVATE KEY-----\nsecret\n-----END RSA PRIVATE KEY-----\n"
  @cipher ~s|{"p":"XSkq3tQ+CSlMmM1xdn1C9aEfFut7hBEUc2vJ0NK50jHr5bG8rCWJfzXypaQ+j9O3lrTl4KhrYbGvu8EGsasBHce5NDoF","h":{"iv":"V6/T5KzGHiv8OdH4","at":"d96uLlaAUwmCVwVXH24AEw=="}}|

  defp opts, do: Encryption.keys(@primary, @salt)

  # Longer values are deflated before they are encrypted, and a private key is
  # always long enough. Reading the flag wrong returns plausible binary rubbish
  # for exactly the rows that matter most.
  @fixtures "test/support/data/rails_encrypted.json" |> File.read!() |> Jason.decode!()

  test "reads what Rails wrote" do
    assert {:ok, @plain} = Encryption.decrypt(@cipher, opts())
  end

  test "reads a value Rails compressed on the way in" do
    assert {:ok, pem} = Encryption.decrypt(@fixtures["private_cipher"], opts())

    assert pem == @fixtures["private_pem"]
  end

  test "and a short one, which it does not compress" do
    assert {:ok, secret} = Encryption.decrypt(@fixtures["otp_cipher"], opts())

    assert secret == @fixtures["otp"]
  end

  test "derives the key Rails derives" do
    # PBKDF2-HMAC-SHA1, 65536 iterations, 32 bytes, checked against the key
    # ActiveRecord::Encryption produced for these same inputs.
    assert Base.encode16(Encryption.derive(@primary, @salt), case: :lower) ==
             "8e3fcf2212a4fd930fb021f659fc51063c2e284e48b590bff032a058b4752df0"
  end

  test "the wrong key does not half-work" do
    # A private key decrypted with the wrong key is bytes that look like a key
    # and sign nothing, which is worse than a refusal.
    assert {:error, :cannot_decrypt} =
             Encryption.decrypt(@cipher, Encryption.keys("wrong", @salt))
  end

  test "a tampered value is refused" do
    tampered = String.replace(@cipher, "XSkq", "XSkr")

    assert {:error, _reason} = Encryption.decrypt(tampered, opts())
  end

  test "something that is not an envelope is said not to be" do
    assert {:error, :not_an_envelope} =
             Encryption.decrypt("-----BEGIN RSA PRIVATE KEY-----", opts())

    assert {:error, :missing} = Encryption.decrypt(nil, opts())
    assert {:error, :missing} = Encryption.decrypt("", opts())
  end

  test "tells a ciphertext column from a plaintext one" do
    # Mastodon has both: the legacy account key is a bare PEM.
    assert Encryption.encrypted?(@cipher)
    refute Encryption.encrypted?(@plain)
    refute Encryption.encrypted?(nil)
  end
end

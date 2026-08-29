defmodule Abuuba.WebPush.VAPID do
  @moduledoc """
  Proving to a push service which server a message came from.

  A push service will not forward a message from nobody: it wants a signed
  assertion naming the origin the subscription was made for and a way to reach
  whoever runs it. That is what VAPID is, and it is why the public key appears
  in this server's instance document — a browser has to know it before it
  subscribes, and a subscription made against one key cannot be pushed to with
  another.

  ES256 rather than anything else, because that is the only algorithm the
  specification allows and the only one push services accept.
  """

  alias Abuuba.Federation.URIs
  alias Abuuba.WebPush.Encryption

  # Twelve hours. Push services refuse anything longer, and a token that is
  # about to expire mid-flight is one the service rejects for reasons nobody
  # can see from here.
  @lifetime_seconds 12 * 60 * 60

  @doc """
  The public key a browser needs before it can subscribe.
  """
  @spec public_key() :: String.t() | nil
  def public_key, do: config()[:public_key]

  @doc """
  Whether this server can push at all.

  Without a keypair it cannot, and saying so plainly is better than accepting
  subscriptions that will never be delivered to.
  """
  @spec configured?() :: boolean()
  def configured?, do: is_binary(public_key()) and is_binary(config()[:private_key])

  @doc """
  The `Authorization` header for one push service.

  The audience is the push service's own origin rather than the endpoint, which
  is what the specification says and what the services check.
  """
  @spec authorization(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def authorization(endpoint) do
    with true <- configured?() or {:error, :not_configured},
         %URI{scheme: scheme, host: host} when is_binary(host) <- URI.parse(endpoint),
         {:ok, private} <- Encryption.decode(config()[:private_key]) do
      claims = %{
        "aud" => "#{scheme}://#{host}",
        "exp" => System.os_time(:second) + @lifetime_seconds,
        "sub" => subject()
      }

      {:ok, "vapid t=#{sign(claims, private)}, k=#{public_key()}"}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_configured}
    end
  end

  @doc """
  Generates a keypair, for an operator setting this up.
  """
  @spec generate_keypair() :: %{public_key: String.t(), private_key: String.t()}
  def generate_keypair do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{public_key: Encryption.url_encode(public), private_key: Encryption.url_encode(private)}
  end

  # A push service uses this to reach whoever runs the server when something is
  # wrong with its messages, so a real address matters more than it looks.
  defp subject do
    config()[:subject] || "mailto:admin@#{URIs.local_host()}"
  end

  defp sign(claims, private_key) do
    header = %{"typ" => "JWT", "alg" => "ES256"}

    signing_input =
      Encryption.url_encode(Jason.encode!(header)) <>
        "." <> Encryption.url_encode(Jason.encode!(claims))

    signature =
      signing_input
      |> :public_key.sign(:sha256, ec_private_key(private_key))
      |> der_to_raw()

    signing_input <> "." <> Encryption.url_encode(signature)
  end

  # The curve is named by its object identifier rather than by the atom: the
  # atom is what the docs call it and what the record refuses.
  @secp256r1 {1, 2, 840, 10_045, 3, 1, 7}

  defp ec_private_key(private_key) do
    {:ECPrivateKey, 1, private_key, {:namedCurve, @secp256r1}, :asn1_NOVALUE, :asn1_NOVALUE}
  end

  # `:public_key.sign/3` produces a DER-encoded pair, and JWS wants the two
  # integers concatenated at a fixed width. A DER signature sent as-is is
  # rejected by every push service with no explanation.
  defp der_to_raw(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)

    pad(r) <> pad(s)
  end

  defp pad(integer) do
    binary = :binary.encode_unsigned(integer)

    String.duplicate(<<0>>, 32 - byte_size(binary)) <> binary
  end

  defp config, do: Application.get_env(:abuuba, :web_push, [])
end

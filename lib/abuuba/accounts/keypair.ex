defmodule Abuuba.Accounts.Keypair do
  @moduledoc """
  A signing key belonging to an account.

  Every local account signs its outgoing activities, and every server that
  receives one verifies the signature against the public half it fetched from
  the actor document. That makes the private key the account's identity: anyone
  who holds it can post as that account anywhere on the fediverse. It is stored
  encrypted, see `Abuuba.Vault`.

  This is a table rather than a pair of columns on `accounts` because a key has
  a life of its own. It can be rotated after a leak, revoked, or given an
  expiry, and each of those has to leave the old key readable so that
  already-delivered activities can still be verified. A partial unique index
  keeps at most one unrevoked private key per account, so "the key this account
  signs with" is never ambiguous.

  A row with no private key is the public half of somebody else's key, which is
  what we keep for remote actors.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account

  # 2048 is what the fediverse interoperates on. Anything shorter is rejected
  # by other servers; ed25519 is the intended second entry, not a replacement.
  @rsa_bits 2048
  @rsa_exponent 65_537

  schema "keypairs" do
    field :type, Ecto.Enum, values: [rsa_2048: "rsa_2048", ed25519: "ed25519"], default: :rsa_2048
    # The id this key calls itself, as the peer wrote it. Only remote keys
    # carry one; ours are named `<actor>#main-key` and derived where needed.
    field :key_id, :string
    field :public_key, :string
    field :private_key, Abuuba.Encrypted.Binary
    field :revoked_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :account, Account, type: Abuuba.Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Changeset for creating a keypair.
  """
  def changeset(keypair, attrs) do
    keypair
    |> cast(attrs, [
      :account_id,
      :type,
      :key_id,
      :public_key,
      :private_key,
      :revoked_at,
      :expires_at
    ])
    |> validate_required([:account_id, :type, :public_key])
    |> unique_constraint(:account_id, name: :keypairs_one_active_private_key_per_account)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Changeset that revokes a key.

  Separate from `changeset/2` so that revoking cannot also move the key to
  another account: `account_id` is not castable here, and a live private key
  handed to a different actor is that actor's identity stolen.
  """
  def revoke_changeset(keypair, at \\ nil) do
    change(keypair, revoked_at: at || DateTime.utc_now())
  end

  @doc """
  Changeset for giving a key an expiry.
  """
  def expiry_changeset(keypair, expires_at) do
    change(keypair, expires_at: expires_at)
  end

  @doc """
  Generates a fresh RSA keypair as PEM.

  The public half is SubjectPublicKeyInfo, the `BEGIN PUBLIC KEY` form that
  ActivityPub actor documents carry and that other servers expect.
  """
  @spec generate() :: %{type: :rsa_2048, public_key: String.t(), private_key: String.t()}
  def generate do
    private = :public_key.generate_key({:rsa, @rsa_bits, @rsa_exponent})

    %{
      type: :rsa_2048,
      public_key: private |> public_from_private() |> encode_pem(:SubjectPublicKeyInfo),
      private_key: encode_pem(private, :RSAPrivateKey)
    }
  end

  @doc """
  Whether the key may still be used for signing.

  Requires the private half to be a binary, not merely present. Cloak's AES.GCM
  cipher reports a wrong key as the bare atom `:error` rather than failing, so
  `private_key` really can come back as something that is neither nil nor a
  key. Treating that as usable would carry the mistake all the way to a
  signing call and crash there instead.
  """
  def active?(%__MODULE__{revoked_at: revoked_at, expires_at: expires_at, private_key: private})
      when is_binary(private) do
    is_nil(revoked_at) and not expired?(expires_at)
  end

  def active?(%__MODULE__{}), do: false

  @doc """
  Whether the private half failed to decrypt, which means the configured
  `CLOAK_KEY` is not the one this row was written with.
  """
  def undecryptable?(%__MODULE__{private_key: private}) do
    not is_nil(private) and not is_binary(private)
  end

  defp expired?(nil), do: false
  defp expired?(at), do: DateTime.after?(DateTime.utc_now(), at)

  defp public_from_private(private) do
    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other} = private
    {:RSAPublicKey, modulus, exponent}
  end

  defp encode_pem(key, type) do
    [:public_key.pem_entry_encode(type, key)] |> :public_key.pem_encode()
  end
end

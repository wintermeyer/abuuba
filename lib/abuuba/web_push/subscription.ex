defmodule Abuuba.WebPush.Subscription do
  @moduledoc """
  One device that wants to be told about a notification.

  Keyed on the access token rather than on the account. A person has the same
  account on a phone and a laptop and expects both to buzz, and each is a
  different app holding a different token; keyed on the account, the second to
  subscribe would silently replace the first and one device would go quiet with
  nothing to show why.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.OAuth.AccessToken
  alias Abuuba.Snowflake

  @policies ~w(all followed follower none)
  @encodings ~w(aes128gcm aesgcm)

  schema "push_subscriptions" do
    field :endpoint, :string
    field :key_p256dh, :string
    field :key_auth, :string
    field :alerts, :map, default: %{}
    field :policy, :string, default: "all"
    field :encoding, :string, default: "aes128gcm"

    belongs_to :access_token, AccessToken, type: Snowflake
    belongs_to :account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :access_token_id,
      :account_id,
      :endpoint,
      :key_p256dh,
      :key_auth,
      :alerts,
      :policy,
      :encoding
    ])
    |> validate_required([:access_token_id, :account_id, :endpoint, :key_p256dh, :key_auth])
    |> validate_endpoint()
    |> validate_inclusion(:policy, @policies)
    |> validate_inclusion(:encoding, @encodings)
    |> unique_constraint(:access_token_id)
    |> foreign_key_constraint(:access_token_id)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Whether this device asked to be told about a notification of this type.

  Absent means no. A device that did not name a type did not ask for it, and
  guessing "probably yes" is how somebody's phone buzzes at three in the
  morning for something they turned off.
  """
  @spec wants?(t(), String.t()) :: boolean()
  def wants?(%__MODULE__{alerts: alerts}, type), do: Map.get(alerts, type, false) == true

  @doc """
  The policies a subscription may have.
  """
  @spec policies() :: [String.t()]
  def policies, do: @policies

  # An https URL and nothing else. The endpoint is fetched by this server, so
  # anything else is a way to point it somewhere it should not go.
  defp validate_endpoint(changeset) do
    validate_change(changeset, :endpoint, fn :endpoint, endpoint ->
      case URI.parse(endpoint) do
        %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
        _ -> [endpoint: "must be an https URL"]
      end
    end)
  end
end

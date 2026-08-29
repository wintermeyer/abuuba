defmodule Abuuba.EmailSubscriptions.Subscription do
  @moduledoc """
  One address that asked to hear from one account. See `Abuuba.EmailSubscriptions`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @foreign_key_type Snowflake

  # The longest an address may be, from RFC 5321. Not a guess at what looks
  # reasonable: a column that refuses a valid address is a bug somebody cannot
  # work around.
  @max_email 320

  schema "email_subscriptions" do
    field :email, :string
    field :locale, :string, default: "en"
    field :token, :string
    field :confirmed_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:account_id, :email, :locale, :token, :confirmed_at])
    |> update_change(:email, &normalise/1)
    |> validate_required([:account_id, :email, :token])
    |> validate_length(:email, max: @max_email)
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s.]+\.[^@\s]+$/,
      message: "must be a valid email address"
    )
    # Reported against `:email` rather than the pair, because the address is
    # the only half the submitter typed and the only half they could fix.
    |> unique_constraint(:email, name: :email_subscriptions_account_id_email_index)
    |> unique_constraint(:token)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  An address as it is stored.

  Public, because anything looking a row up by address has to ask the same
  question the changeset asked. Two places normalising by hand is two places
  that quietly stop agreeing the day the rule changes, and the query that then
  matches nothing raises nothing.

  Addresses are typed by two different people here: the one who subscribed and
  the one who unsubscribes. Case and stray whitespace must not make those two
  different rows.
  """
  @spec normalise(String.t() | nil) :: String.t() | nil
  def normalise(nil), do: nil
  def normalise(email), do: email |> to_string() |> String.trim() |> String.downcase()
end

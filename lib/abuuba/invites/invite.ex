defmodule Abuuba.Invites.Invite do
  @moduledoc """
  A code that lets somebody in, with a budget.

  Uses and an expiry rather than a single-shot token, because the common case
  is one link handed to a group. `max_uses` is null for "as many as you like":
  zero would read as none, which is the opposite of what somebody leaving the
  field empty meant.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  schema "invites" do
    field :code, :string
    field :comment, :string
    field :expires_at, :utc_datetime_usec
    field :max_uses, :integer
    field :uses, :integer, default: 0
    field :autofollow, :boolean, default: false

    belongs_to :account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:account_id, :code, :comment, :expires_at, :max_uses, :autofollow])
    |> validate_required([:account_id, :code])
    |> validate_number(:max_uses, greater_than: 0)
    |> validate_length(:comment, max: 420)
    |> unique_constraint(:code)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Whether this invite still lets somebody in.
  """
  @spec usable?(t(), DateTime.t()) :: boolean()
  def usable?(invite, now \\ DateTime.utc_now()) do
    not expired?(invite, now) and not used_up?(invite)
  end

  @doc "Whether the expiry has passed."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  @doc "Whether every use has been spent."
  @spec used_up?(t()) :: boolean()
  def used_up?(%__MODULE__{max_uses: nil}), do: false
  def used_up?(%__MODULE__{max_uses: max, uses: uses}), do: uses >= max
end

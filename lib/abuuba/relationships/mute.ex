defmodule Abuuba.Relationships.Mute do
  @moduledoc """
  One account hiding another's posts without refusing them.

  A mute is quiet: the muted account is not told, keeps following, and keeps
  being able to reply. Whether their notifications are hidden too is a separate
  choice, because muting a loud account is not the same as wanting to miss it
  answering you.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  schema "mutes" do
    field :hide_notifications, :boolean, default: true
    field :expires_at, :utc_datetime_usec

    belongs_to :account, Account, type: Snowflake
    belongs_to :target_account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(mute, attrs) do
    mute
    |> cast(attrs, [:account_id, :target_account_id, :hide_notifications, :expires_at])
    |> validate_required([:account_id, :target_account_id])
    |> validate_not_self()
    |> unique_constraint([:account_id, :target_account_id])
    |> check_constraint(:target_account_id, name: :mutes_no_self_reference)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:target_account_id)
  end

  @doc """
  Whether the mute is still in force.
  """
  def active?(%__MODULE__{expires_at: nil}), do: true

  def active?(%__MODULE__{expires_at: expires_at}),
    do: DateTime.before?(DateTime.utc_now(), expires_at)

  defp validate_not_self(changeset) do
    if get_field(changeset, :account_id) == get_field(changeset, :target_account_id) do
      add_error(changeset, :target_account_id, "cannot be yourself")
    else
      changeset
    end
  end
end

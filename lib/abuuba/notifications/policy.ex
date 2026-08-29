defmodule Abuuba.Notifications.Policy do
  @moduledoc """
  What somebody wants done about notifications from people like this.

  Six axes, each answering the same question about a different kind of
  stranger: accept it, file it under requests, or drop it entirely.

  The defaults are the reference implementation's, and they are deliberately
  not "filter everything". A server whose new accounts hear from nobody looks
  broken to the person who just joined it; the two that default to filtering
  are the two that are actually abused.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @decisions ~w(accept filter drop)
  @axes ~w(for_not_following for_not_followers for_new_accounts for_private_mentions
           for_limited_accounts for_bots)a

  @primary_key false

  schema "notification_policies" do
    field :for_not_following, :string, default: "accept"
    field :for_not_followers, :string, default: "accept"
    field :for_new_accounts, :string, default: "accept"
    field :for_private_mentions, :string, default: "filter"
    field :for_limited_accounts, :string, default: "filter"
    field :for_bots, :string, default: "accept"

    belongs_to :account, Account, type: Snowflake, primary_key: true

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:account_id | @axes])
    |> validate_required([:account_id])
    |> validate_axes()
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  The six axes.
  """
  @spec axes() :: [atom()]
  def axes, do: @axes

  @doc """
  What an axis may be set to.
  """
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  defp validate_axes(changeset) do
    Enum.reduce(@axes, changeset, &validate_inclusion(&2, &1, @decisions))
  end
end

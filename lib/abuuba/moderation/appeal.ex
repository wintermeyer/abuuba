defmodule Abuuba.Moderation.Appeal do
  @moduledoc """
  Somebody saying a decision about them was wrong.

  One per strike. Somebody who can appeal twice can appeal until a different
  moderator happens to be reading, which is not an appeal, it is a lottery.

  The window is twenty days: long enough that somebody who was away can still
  answer, short enough that a moderator is not asked to reconstruct a decision
  from months ago against evidence that has since been deleted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Moderation.Strike

  @window_days 20
  @max_text 2_000

  schema "appeals" do
    field :text, :string, default: ""
    field :approved_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec

    belongs_to :account_warning, Strike
    belongs_to :account, Account
    belongs_to :approved_by_account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(appeal, attrs) do
    appeal
    |> cast(attrs, [:account_warning_id, :account_id, :text])
    |> validate_required([:account_warning_id, :account_id, :text])
    |> validate_length(:text, min: 1, max: @max_text)
    |> unique_constraint(:account_warning_id)
    |> foreign_key_constraint(:account_warning_id)
  end

  @doc false
  def decision_changeset(appeal, attrs) do
    cast(appeal, attrs, [:approved_at, :rejected_at, :approved_by_account_id])
  end

  @doc """
  How long somebody has to appeal.
  """
  @spec window_days() :: pos_integer()
  def window_days, do: @window_days

  @doc """
  How long an appeal may be.
  """
  @spec max_text() :: pos_integer()
  def max_text, do: @max_text

  @doc """
  Whether a strike is still within its window.
  """
  @spec open?(Strike.t(), DateTime.t()) :: boolean()
  def open?(%Strike{inserted_at: at}, now \\ DateTime.utc_now()) do
    DateTime.diff(now, at, :day) < @window_days
  end

  @doc """
  Whether anybody has decided it yet.
  """
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{approved_at: nil, rejected_at: nil}), do: true
  def pending?(%__MODULE__{}), do: false
end

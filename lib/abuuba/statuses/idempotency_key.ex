defmodule Abuuba.Statuses.IdempotencyKey do
  @moduledoc """
  What a client got the last time it sent this `Idempotency-Key`.

  A client that times out while posting has no way to know whether the post
  landed, so it retries. Without a record of the key, that retry is a second
  post, and the person sees themselves say the same thing twice.

  Kept per account, so one client's key cannot collide with another's, and
  swept rather than kept forever: the window only has to outlast a retry.

  A key names either a post or a scheduled post, never both and never neither.
  Scheduling was the half that was missing, and it is the half where the
  duplicate is invisible: a second post shows up in the timeline immediately,
  a second scheduled post shows up whenever it was set for.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Statuses.Status

  @primary_key false

  schema "idempotency_keys" do
    field :key, :string, primary_key: true

    belongs_to :account, Account, type: Snowflake, primary_key: true
    belongs_to :status, Status, type: Snowflake
    belongs_to :scheduled_status, ScheduledStatus, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:account_id, :key, :status_id, :scheduled_status_id])
    |> validate_required([:account_id, :key])
    |> validate_one_result()
    |> validate_length(:key, max: 255)
    |> unique_constraint([:account_id, :key], name: :idempotency_keys_pkey)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:status_id)
    |> foreign_key_constraint(:scheduled_status_id)
  end

  # A key that names nothing would answer a retry with "yes, you already did
  # that" and nothing to show for it, which is worse than not remembering the
  # key at all.
  defp validate_one_result(changeset) do
    case {get_field(changeset, :status_id), get_field(changeset, :scheduled_status_id)} do
      {nil, nil} -> add_error(changeset, :status_id, "must name a post")
      {id, other} when not is_nil(id) and not is_nil(other) -> both(changeset)
      _one_of_them -> changeset
    end
  end

  defp both(changeset),
    do: add_error(changeset, :status_id, "cannot name both a post and a scheduled post")
end

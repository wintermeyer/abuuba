defmodule Abuuba.Webhooks.Delivery do
  @moduledoc """
  One attempt to tell a webhook about something. See `Abuuba.Webhooks`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Webhooks.Webhook

  schema "webhook_deliveries" do
    field :event, :string
    field :status, :integer
    field :error, :string
    field :attempt, :integer, default: 1

    belongs_to :webhook, Webhook

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:webhook_id, :event, :status, :error, :attempt])
    |> validate_required([:webhook_id, :event])
    |> update_change(:error, &String.slice(to_string(&1), 0, 300))
    |> foreign_key_constraint(:webhook_id)
  end

  @doc """
  Whether the receiver took it.
  """
  @spec delivered?(t()) :: boolean()
  def delivered?(%__MODULE__{status: status}) when is_integer(status),
    do: status >= 200 and status < 300

  def delivered?(_delivery), do: false
end

defmodule Abuuba.Webhooks.Webhook do
  @moduledoc """
  One place this server tells about things. See `Abuuba.Webhooks`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @events ~w(
    account.created account.approved account.updated
    report.created report.updated
    status.created status.updated
  )

  schema "webhooks" do
    field :url, :string
    field :events, {:array, :string}, default: []
    field :enabled, :boolean, default: false
    field :secret, :string, redact: true

    has_many :deliveries, Abuuba.Webhooks.Delivery

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  The events a webhook may ask for.
  """
  @spec events() :: [String.t()]
  def events, do: @events

  @doc false
  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:url, :events, :enabled, :secret])
    |> validate_required([:url, :secret])
    |> validate_url()
    |> validate_events()
    |> unique_constraint(:url)
  end

  # `https` and nothing else. This is an admin typing a URL, and a typo landing
  # on `file://` or on a private address is a mistake worth catching where it
  # is made rather than in a worker an hour later. The outbound layer refuses
  # a private address again at delivery time; this is the first of two.
  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case URI.parse(url) do
        %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
        _ -> [url: "must be an https URL"]
      end
    end)
  end

  # An unknown event name is refused rather than dropped. Silently keeping the
  # ones it recognised would leave an admin watching for something this server
  # will never send, with nothing anywhere saying so.
  defp validate_events(changeset) do
    validate_change(changeset, :events, fn :events, events ->
      case Enum.reject(List.wrap(events), &(&1 in @events)) do
        [] -> []
        unknown -> [events: "does not include #{Enum.join(unknown, ", ")}"]
      end
    end)
  end
end

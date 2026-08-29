defmodule Abuuba.Federation.Relay do
  @moduledoc """
  A relay this server subscribes to.

  Not an account, because a relay is not somebody anybody follows: it is an
  inbox that forwards public posts on to everybody subscribed to it. Nothing in
  the account model would have a sensible answer for it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @states ~w(idle pending accepted rejected)a

  schema "relays" do
    field :inbox_url, :string
    field :state, Ecto.Enum, values: @states, default: :idle
    field :follow_activity_id, :string

    # Why it is not working, so the admin does not have to tell "failing
    # quietly" apart from "nobody has posted yet" by reading logs.
    field :last_error, :string
    field :last_error_at, :utc_datetime_usec
    field :last_delivery_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(relay, attrs) do
    relay
    |> cast(attrs, [
      :inbox_url,
      :state,
      :follow_activity_id,
      :last_error,
      :last_error_at,
      :last_delivery_at
    ])
    |> validate_required([:inbox_url])
    |> validate_inbox_url()
    |> unique_constraint(:inbox_url)
    |> unique_constraint(:follow_activity_id)
  end

  # An https URL and nothing else. A relay address is typed in by an admin, and
  # a typo that lands on `file://` or on a private address is a mistake worth
  # catching where it is made rather than in a worker an hour later.
  defp validate_inbox_url(changeset) do
    validate_change(changeset, :inbox_url, fn :inbox_url, url ->
      case URI.parse(url) do
        %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
        _ -> [inbox_url: "must be an https URL"]
      end
    end)
  end
end

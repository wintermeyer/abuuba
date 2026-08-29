defmodule Abuuba.Exports.Export do
  @moduledoc """
  One archive somebody asked for. See `Abuuba.Exports`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @foreign_key_type Snowflake

  @states ~w(pending running done expired failed)

  # Mastodon's interval, and for the same reasons: building one walks a whole
  # account, and the result is the single most sensitive object this server
  # writes. Somebody who needs another within the week can take the CSVs.
  @cooldown_days 7

  # How long the file stays downloadable. Short, because it is somebody's whole
  # account in one file sitting on a disk, and the person who asked for it
  # usually downloads it within the hour.
  @lifetime_days 2

  # A job killed rather than raised — a deploy, a restart, a timeout — never
  # marks its row. Longer than any archive should take, short enough that
  # nobody is locked out for a day by a node that went away.
  @stall_hours 3

  schema "account_exports" do
    field :state, :string, default: "pending"
    field :path, :string
    field :filename, :string
    field :size, :integer
    field :error, :string
    field :expires_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(export, attrs) do
    export
    |> cast(attrs, [
      :account_id,
      :state,
      :path,
      :filename,
      :size,
      :error,
      :expires_at,
      :finished_at
    ])
    |> validate_required([:account_id, :state])
    |> validate_inclusion(:state, @states)
    |> foreign_key_constraint(:account_id)
  end

  @doc "How long somebody must wait between archives, in days."
  def cooldown_days, do: @cooldown_days

  @doc "How long a built archive stays downloadable, in days."
  def lifetime_days, do: @lifetime_days

  @doc "After how long an unfinished archive is written off, in hours."
  def stall_hours, do: @stall_hours
end

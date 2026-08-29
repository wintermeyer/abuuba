defmodule Abuuba.Imports.Run do
  @moduledoc """
  One run of somebody reading their own archive back in.

  The row is what the settings page watches. It outlives the request that
  started it, so closing the tab does not stop the import and coming back shows
  where it got to rather than nothing.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @states ~w(pending running finished failed)
  @modes ~w(merge overwrite)

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type Snowflake

  schema "account_imports" do
    field :state, :string, default: "pending"
    # What is being read: an archive, or one of the exported lists.
    field :kind, :string, default: "archive"
    # What to do with what is already here. Only meaningful for a list, and the
    # difference between "here are twelve more people I follow" and "this is
    # now everybody I follow".
    field :mode, :string, default: "merge"
    field :filename, :string
    field :path, :string

    field :total, :integer, default: 0
    field :done, :integer, default: 0
    field :imported, :integer, default: 0

    # A list rather than a count: "seventeen posts could not be imported" is
    # not something anybody can act on, and "this one, because its picture was
    # missing" is.
    field :failures, {:array, :map}, default: []
    field :finished_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Changeset for starting one.
  """
  def changeset(archive_import, attrs) do
    archive_import
    |> cast(attrs, [:account_id, :filename, :path, :state, :kind, :mode])
    |> validate_required([:account_id, :path])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:mode, @modes)
    |> unique_constraint(:account_id, name: :account_imports_one_running_per_account)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Changeset for how far it has got.
  """
  def progress_changeset(archive_import, attrs) do
    archive_import
    |> cast(attrs, [:state, :kind, :total, :done, :imported, :failures, :finished_at])
    |> validate_inclusion(:state, @states)
  end

  @doc """
  Whether it is still going.
  """
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{finished_at: nil}), do: true
  def running?(%__MODULE__{}), do: false

  @doc """
  The states a run can be in.
  """
  def states, do: @states

  @doc """
  What to do with what is already there.
  """
  def modes, do: @modes
end

defmodule Abuuba.Moderation.Signup.CanonicalEmailBlock do
  @moduledoc """
  One address this server will not take a new registration from, stored as a
  hash.

  Never the address itself. The list exists to recognise somebody who was
  suspended coming back, which needs a comparison and not the ability to read
  the addresses back out; an admin database that leaks is then a list of
  hashes rather than a list of people.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "canonical_email_blocks" do
    field :canonical_email_hash, :string
    field :reference_account_id, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(block, attrs) do
    block
    |> cast(attrs, [:canonical_email_hash, :reference_account_id])
    |> validate_required([:canonical_email_hash])
    |> unique_constraint(:canonical_email_hash)
  end
end

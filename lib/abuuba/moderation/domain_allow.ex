defmodule Abuuba.Moderation.DomainAllow do
  @moduledoc """
  A domain this server federates with in limited-federation mode.

  Its own table rather than a severity on `Abuuba.Moderation.DomainBlock`,
  because a domain that is not allowed has had no decision taken about it. It
  is simply not on the list, and folding the two together would make an empty
  allowlist read as a thousand blocks nobody wrote.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Moderation.DomainBlock

  schema "domain_allows" do
    field :domain, :string

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(allow, attrs) do
    allow
    |> cast(attrs, [:domain])
    |> validate_required([:domain])
    |> update_change(:domain, &DomainBlock.normalise/1)
    |> validate_length(:domain, min: 1, max: 255)
    |> unique_constraint(:domain)
  end
end

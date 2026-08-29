defmodule Abuuba.Moderation.Signup.EmailDomainBlock do
  @moduledoc """
  A mail domain this server will not take registrations from.

  `allow_with_approval` is the softer answer: not "no", but "a person looks at
  this one". A university that one spammer used is not a university that should
  be shut out.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "email_domain_blocks" do
    field :domain, :string
    field :allow_with_approval, :boolean, default: false
    field :comment, :string

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(block, attrs) do
    block
    |> cast(attrs, [:domain, :allow_with_approval, :comment])
    |> validate_required([:domain])
    |> update_change(:domain, &normalise/1)
    |> validate_length(:domain, min: 1, max: 255)
    |> validate_length(:comment, max: 500)
    |> unique_constraint(:domain)
  end

  @doc "Trimmed, downcased, without a trailing dot or a leading @."
  @spec normalise(String.t() | nil) :: String.t()
  def normalise(domain) do
    domain
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
    |> String.trim_trailing(".")
  end
end

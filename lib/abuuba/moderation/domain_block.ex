defmodule Abuuba.Moderation.DomainBlock do
  @moduledoc """
  This server's decision about another one.

  Distinct from `Abuuba.Relationships.DomainBlock`, which is one person refusing
  a server for themselves. This one is the admin's and applies to everybody
  here.

  ## Severity is a ladder, not a switch

  `noop` does nothing on its own and exists so that a row setting only
  `reject_media` or `reject_reports` has somewhere to live. `silence` takes the
  domain out of everywhere nobody asked for it while leaving the people who
  chose to follow somebody there still following them. `suspend` cuts it off.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Federation.URIs

  @severities ~w(noop silence suspend)

  schema "domain_blocks" do
    field :domain, :string
    field :severity, :string, default: "silence"
    field :reject_media, :boolean, default: false
    field :reject_reports, :boolean, default: false
    field :public_comment, :string
    field :private_comment, :string
    field :obfuscate, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Every severity a block may carry, mildest first.
  """
  @spec severities() :: [String.t()]
  def severities, do: @severities

  @doc """
  How far up the ladder a severity sits. Higher does more.
  """
  @spec rank(String.t()) :: non_neg_integer()
  def rank(severity), do: Enum.find_index(@severities, &(&1 == severity)) || 0

  @doc false
  def changeset(block, attrs) do
    block
    |> cast(attrs, [
      :domain,
      :severity,
      :reject_media,
      :reject_reports,
      :public_comment,
      :private_comment,
      :obfuscate
    ])
    |> validate_required([:domain])
    # Normalised the same way as `accounts.domain`, or a block written with
    # different capitalisation or a trailing dot silently matches nothing.
    |> update_change(:domain, &normalise/1)
    |> validate_length(:domain, min: 1, max: 255)
    |> validate_inclusion(:severity, @severities)
    |> validate_not_ourselves()
    |> unique_constraint(:domain)
  end

  @doc """
  Trims, downcases and drops a trailing dot.
  """
  @spec normalise(String.t() | nil) :: String.t()
  def normalise(domain) do
    domain
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  # Blocking ourselves would silence every local account at once, which is one
  # typo away from taking the whole server down from the inside.
  defp validate_not_ourselves(changeset) do
    validate_change(changeset, :domain, fn :domain, domain ->
      if URIs.local_domain?(domain) do
        [domain: "is this server"]
      else
        []
      end
    end)
  end
end

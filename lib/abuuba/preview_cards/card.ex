defmodule Abuuba.PreviewCards.Card do
  @moduledoc """
  What a link turns out to be.

  One row per address, shared by every post that links it: a news story shared
  by two hundred people is one card, and refreshing it once makes it right
  everywhere.

  `type` is never `rich`. See `Abuuba.PreviewCards` for why.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @types ~w(link photo video)

  schema "preview_cards" do
    field :url, :string
    field :title, :string, default: ""
    field :description, :string, default: ""
    field :type, :string, default: "link"

    field :author_name, :string
    field :author_url, :string
    field :provider_name, :string
    field :provider_url, :string

    field :html, :string, default: ""
    field :width, :integer, default: 0
    field :height, :integer, default: 0

    field :image_url, :string
    field :image_description, :string
    field :blurhash, :string
    field :embed_url, :string, default: ""

    field :fetched_at, :utc_datetime_usec

    belongs_to :author_account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc "The types a card may carry."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc false
  def changeset(card, attrs) do
    card
    |> cast(attrs, [
      :url,
      :title,
      :description,
      :type,
      :author_name,
      :author_url,
      :provider_name,
      :provider_url,
      :author_account_id,
      :html,
      :width,
      :height,
      :image_url,
      :image_description,
      :blurhash,
      :embed_url,
      :fetched_at
    ])
    |> validate_required([:url])
    |> validate_inclusion(:type, @types)
    # Everything here came from a page a stranger wrote, so every string is
    # bounded rather than trusted to be a sensible length.
    |> truncate(:title, 500)
    |> truncate(:description, 1_000)
    |> truncate(:author_name, 200)
    |> truncate(:provider_name, 200)
    |> unique_constraint(:url)
  end

  defp truncate(changeset, field, limit) do
    case get_change(changeset, field) do
      value when is_binary(value) -> put_change(changeset, field, String.slice(value, 0, limit))
      _ -> changeset
    end
  end
end

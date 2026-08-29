defmodule Abuuba.Collections.Collection do
  @moduledoc """
  A curated list of accounts somebody publishes.

  The limits are the reference implementation's, and they are low on purpose: a
  collection is a recommendation, and a list of two hundred people recommends
  nothing. Twenty-five is about as many as anybody reads.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Tag

  @name_max 40
  @description_max 100
  @items_max 25
  @per_account_max 10

  @foreign_key_type Snowflake

  schema "collections" do
    field :name, :string
    field :description, :string, default: ""
    field :sensitive, :boolean, default: false
    field :discoverable, :boolean, default: true
    field :language, :string
    field :item_count, :integer, default: 0
    field :local, :boolean, default: true
    field :uri, :string
    field :url, :string

    belongs_to :account, Account
    belongs_to :tag, Tag, type: :id

    has_many :items, Abuuba.Collections.Item, foreign_key: :collection_id

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  How many accounts one collection may hold.
  """
  @spec items_max() :: pos_integer()
  def items_max, do: @items_max

  @doc """
  How many collections one account may publish.
  """
  @spec per_account_max() :: pos_integer()
  def per_account_max, do: @per_account_max

  @doc false
  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:name, :description, :sensitive, :discoverable, :language, :tag_id])
    |> validate_required([:name])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: @name_max)
    |> validate_length(:description, max: @description_max)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:tag_id)
  end

  @doc false
  def owner_changeset(collection, account_id, attrs) do
    collection
    |> changeset(attrs)
    |> put_change(:account_id, account_id)
  end
end

defmodule Abuuba.Filters.Keyword do
  @moduledoc """
  One spelling a filter looks for.

  `whole_word` decides whether "cat" should match "concatenate". Almost never,
  which is why a client offers the choice rather than guessing — and why it
  defaults to true when a client says nothing, which is what the reference
  implementation does and therefore what every client that omits it expects.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Snowflake

  @foreign_key_type Snowflake

  schema "filter_keywords" do
    field :keyword, :string
    field :whole_word, :boolean, default: true
    belongs_to :filter, Abuuba.Filters.Filter

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(keyword, attrs) do
    keyword
    |> cast(attrs, [:filter_id, :keyword, :whole_word])
    |> validate_required([:filter_id, :keyword])
    |> update_change(:keyword, &String.trim/1)
    |> validate_length(:keyword, min: 1, max: 512)
    |> foreign_key_constraint(:filter_id)
  end
end

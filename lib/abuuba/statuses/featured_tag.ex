defmodule Abuuba.Statuses.FeaturedTag do
  @moduledoc """
  A hashtag somebody has put on their own profile.

  A row of its own rather than a list on the account, because it has an
  identity a client can act on: the API hands out this row's id and deletes by
  it, and a tag featured by two people is two rows about one tag.

  How many posts carry it, and when the last one was, are counted rather than
  stored. The reference implementation keeps a running total in columns beside
  this row and has to maintain it on every post, every delete and every edit;
  counting is one grouped query for a whole profile and cannot drift.
  """

  use Ecto.Schema

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Tag

  @foreign_key_type Snowflake

  schema "featured_tags" do
    belongs_to :account, Account
    belongs_to :tag, Tag, type: :id

    # Filled in by `Abuuba.Statuses.featured_tags/1` rather than stored. See the
    # module doc.
    field :statuses_count, :integer, virtual: true, default: 0
    field :last_status_at, :utc_datetime_usec, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}
end

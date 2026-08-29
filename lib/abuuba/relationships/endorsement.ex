defmodule Abuuba.Relationships.Endorsement do
  @moduledoc """
  One account saying, on its own profile, that another is worth following.

  Not a relationship in the sense the rest of this directory means it: it says
  nothing about what either account may read or receive, and the account being
  endorsed is neither asked nor notified. It is a piece of profile copy that
  happens to point at somebody.

  It lives here anyway because it is a row about a pair of accounts, and the
  reader of that pair is the same relationship entity that answers whether you
  follow, block or mute them.
  """

  use Ecto.Schema

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @foreign_key_type Snowflake

  schema "endorsements" do
    belongs_to :account, Account
    belongs_to :target_account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}
end

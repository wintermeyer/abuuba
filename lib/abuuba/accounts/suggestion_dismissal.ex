defmodule Abuuba.Accounts.SuggestionDismissal do
  @moduledoc """
  Somebody the reader has told this server to stop suggesting.

  See `Abuuba.Accounts.Suggestions`: the list is computed on every request, so a
  dismissal that was not written down would last until the page reloaded.
  """

  use Ecto.Schema

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @foreign_key_type Snowflake

  schema "suggestion_dismissals" do
    belongs_to :account, Account
    belongs_to :target_account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}
end

defmodule Abuuba.Statuses.Draft do
  @moduledoc """
  A post somebody started and has not sent.

  ## Why this is not an unpublished status

  Same reason as a scheduled post: an unsent post filed among the sent ones is
  one that the first query which forgets to exclude it will publish. So a draft
  is the composer's own state, stored as the parameters the box holds rather
  than as a half-built status row.

  Nothing here federates, nothing here is shown to anybody else. There is no
  URI, no visibility to enforce and no counter to keep. It is a piece of paper
  on somebody's own desk, and the only thing this module has to get right is
  not losing it.

  ## The ceiling

  Autosave writes without being asked, so the number of rows one account can
  accumulate is bounded by how much they type rather than by how many drafts
  they meant to keep. The limit stops that, and it stops it by refusing a new
  draft rather than by deleting an old one: making room by throwing away
  something somebody wrote is the one failure this feature must not have.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @limit 50

  schema "drafts" do
    field :params, :map, default: %{}

    belongs_to :account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:account_id, :params])
    |> validate_required([:account_id])
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  How many drafts one account may keep.
  """
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  Whether there is anything in the box worth keeping.

  A warning with no words counts: somebody who typed only the content warning
  has still written something, and losing it because the main field is empty
  would be the same bug as losing anything else.
  """
  @spec worth_keeping?(map()) :: boolean()
  def worth_keeping?(params) do
    Enum.any?(~w(text spoiler_text), fn key ->
      params |> Map.get(key, "") |> to_string() |> String.trim() != ""
    end) or params |> Map.get("poll_options", []) |> Enum.any?(&(String.trim(&1) != ""))
  end
end

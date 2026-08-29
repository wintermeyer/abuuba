defmodule Abuuba.Notifications.Notification do
  @moduledoc """
  One thing somebody is told about.

  The type list is the client API's rather than ours, because an app renders a
  type it knows and ignores one it does not. Adding one nobody has heard of is
  safe; renaming one breaks every client at once.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status

  @types ~w(
    mention status reblog follow follow_request favourite poll update
    quote severed_relationships moderation_warning annual_report
    collection_add
    admin.sign_up admin.report
  )

  # Which of them a policy may divert. A follow request being filtered is
  # sensible; being told your own scheduled post went out is not something
  # anybody asked a stranger for, so it cannot be.
  @filterable ~w(mention reblog follow follow_request favourite poll update quote)

  schema "notifications" do
    field :type, :string
    field :group_key, :string
    field :filtered, :boolean, default: false

    belongs_to :account, Account, type: Snowflake
    belongs_to :from_account, Account, type: Snowflake
    belongs_to :status, Status, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:account_id, :from_account_id, :type, :status_id, :group_key, :filtered])
    |> validate_required([:account_id, :from_account_id, :type])
    |> validate_inclusion(:type, @types)
    |> put_group_key()
    |> unique_constraint([:account_id, :from_account_id, :type, :status_id],
      name: :notifications_one_per_event
    )
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:from_account_id)
  end

  @doc """
  Every notification type this server can produce.
  """
  @spec types() :: [String.t()]
  def types, do: @types

  @doc """
  The types a policy may divert.
  """
  @spec filterable_types() :: [String.t()]
  def filterable_types, do: @filterable

  @doc """
  Whether a type can be filtered at all.
  """
  @spec filterable?(String.t()) :: boolean()
  def filterable?(type), do: type in @filterable

  # Twenty people boosting one post is one thing that happened, so they share a
  # key. A follow is not: twenty follows are twenty people, and a client shows
  # them as one line naming several, which it can only do if the key groups
  # them. Anything without an obvious grouping gets its own key, which renders
  # as a group of one.
  defp put_group_key(changeset) do
    case get_field(changeset, :group_key) do
      nil -> put_change(changeset, :group_key, derive_group_key(changeset))
      _ -> changeset
    end
  end

  defp derive_group_key(changeset) do
    type = get_field(changeset, :type)
    status_id = get_field(changeset, :status_id)

    cond do
      type in ~w(reblog favourite quote) and status_id -> "#{type}-#{status_id}"
      type in ~w(follow follow_request) -> "#{type}-#{get_field(changeset, :account_id)}"
      true -> "ungrouped-#{System.unique_integer([:positive, :monotonic])}"
    end
  end
end

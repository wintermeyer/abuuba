defmodule Abuuba.Moderation.Report do
  @moduledoc """
  Somebody saying an account has done something wrong.

  A report is an opinion, not a finding. It names an account, optionally some
  of its posts as evidence, and what kind of problem the reporter thinks it is.
  Nothing about it acts on its own: a moderator reads it and decides.

  The same shape covers a report filed here and one arriving from another
  server as a `Flag`. A remote report carries the activity's `uri`, which is
  what makes a redelivery a duplicate rather than a second report.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account

  # Mastodon's four, so a client that can report on one server can report here.
  @categories ~w(other spam legal violation)

  # Long enough for a real explanation, short enough that a report cannot be
  # used to write a novel into the database.
  @max_comment 1_000

  schema "reports" do
    field :category, :string, default: "other"
    field :comment, :string, default: ""
    field :uri, :string
    field :forwarded, :boolean, default: false
    field :rule_ids, {:array, :integer}, default: []
    field :status_ids, {:array, :integer}, default: []

    field :action_taken_at, :utc_datetime_usec

    belongs_to :account, Account
    belongs_to :target_account, Account
    belongs_to :assigned_account, Account
    belongs_to :action_taken_by_account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :account_id,
      :target_account_id,
      :category,
      :comment,
      :uri,
      :forwarded,
      :rule_ids,
      :status_ids
    ])
    |> validate_required([:target_account_id])
    |> validate_inclusion(:category, @categories)
    |> validate_length(:comment, max: @max_comment)
    |> validate_not_self()
    |> unique_constraint(:uri)
    |> foreign_key_constraint(:target_account_id)
  end

  @doc false
  def resolution_changeset(report, attrs) do
    cast(report, attrs, [:action_taken_at, :action_taken_by_account_id, :assigned_account_id])
  end

  @doc """
  Changeset for a moderator correcting what a report is filed under.

  The category and the rules only. The comment is the reporter's own words and
  is not a moderator's to rewrite: a report whose text can be edited by the
  person deciding on it is not evidence of anything.
  """
  def correction_changeset(report, attrs) do
    report
    |> cast(attrs, [:category, :rule_ids])
    |> validate_inclusion(:category, @categories)
  end

  @doc """
  The categories a report may have.
  """
  @spec categories() :: [String.t()]
  def categories, do: @categories

  @doc """
  How long a comment may be.
  """
  @spec max_comment() :: pos_integer()
  def max_comment, do: @max_comment

  @doc """
  Whether anybody has dealt with it yet.
  """
  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{action_taken_at: nil}), do: false
  def resolved?(%__MODULE__{}), do: true

  # Reporting yourself is either a mistake or a way to put noise in the queue,
  # and neither is worth a row.
  defp validate_not_self(changeset) do
    reporter = get_field(changeset, :account_id)
    target = get_field(changeset, :target_account_id)

    if not is_nil(reporter) and reporter == target do
      add_error(changeset, :target_account_id, "cannot report yourself")
    else
      changeset
    end
  end
end

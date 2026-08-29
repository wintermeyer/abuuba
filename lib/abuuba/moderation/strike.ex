defmodule Abuuba.Moderation.Strike do
  @moduledoc """
  What a moderator decided about one account, as its owner reads it.

  The audit log is what moderators read about each other. This is the other
  half: what the person on the receiving end is told. Without it the answer to
  "why can nobody see my posts" is nothing at all, and somebody who has done
  nothing wrong has no way to find out that they have.

  `overruled_at` is set when an appeal succeeds. The row stays, because the
  decision was made and later reversed, and erasing it would leave the appeal
  pointing at nothing.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Moderation.Report

  # The ladder, in order of severity. `none` is a warning with no state change,
  # which is the most common outcome and the one most worth being able to
  # record: telling somebody is a moderation action even when nothing else
  # happens.
  @actions ~w(none disable mark_statuses_as_sensitive delete_statuses silence suspend)

  schema "account_warnings" do
    field :action, :string, default: "none"
    field :text, :string, default: ""
    field :status_ids, {:array, :integer}, default: []
    field :overruled_at, :utc_datetime_usec

    belongs_to :account, Account
    belongs_to :target_account, Account
    belongs_to :report, Report

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(strike, attrs) do
    strike
    |> cast(attrs, [
      :account_id,
      :target_account_id,
      :action,
      :text,
      :status_ids,
      :report_id,
      :overruled_at
    ])
    |> validate_required([:target_account_id, :action])
    |> validate_inclusion(:action, @actions)
    |> validate_length(:text, max: 5_000)
    |> foreign_key_constraint(:target_account_id)
  end

  @doc """
  Every action a moderator may take, mildest first.
  """
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc """
  Whether an action changes anything that can be put back.

  A suspension or a silencing is a state that can be lifted. Deleting somebody's
  posts is not: an appeal against it can be upheld and the posts are still gone,
  which is why it is worth saying so before it is taken.
  """
  @spec undoable?(String.t()) :: boolean()
  def undoable?(action), do: action in ~w(disable mark_statuses_as_sensitive silence suspend)

  @doc """
  Whether it still stands.
  """
  @spec standing?(t()) :: boolean()
  def standing?(%__MODULE__{overruled_at: nil}), do: true
  def standing?(%__MODULE__{}), do: false
end

defmodule Abuuba.Statuses.ScheduledStatus do
  @moduledoc """
  A post somebody has written but not published yet.

  The request is kept as it arrived rather than as a half-built status row.
  Storing an unpublished status among the published ones would mean every query
  for a real post has to remember to exclude the ones that are not posts yet,
  and the first query that forgets publishes somebody's draft.

  ## The five-minute floor

  A time less than five minutes away is refused. The reference implementation
  does the same, and the reason is that scheduling is a queue rather than a
  timer: a post due in ten seconds would be published late often enough that
  the feature would look broken, and a client wanting to post now can post now.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @minimum_notice_seconds 5 * 60

  # A queue nobody bounded is one somebody fills, and every entry is work the
  # publisher has to do at its appointed minute. The reference implementation
  # uses the same two numbers, so a client that knows one server knows this one.
  @limit 300
  @daily_limit 25

  schema "scheduled_statuses" do
    field :scheduled_at, :utc_datetime_usec
    field :params, :map, default: %{}
    field :media_attachment_ids, {:array, :integer}, default: []

    belongs_to :account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(scheduled, attrs, now \\ DateTime.utc_now()) do
    scheduled
    |> cast(attrs, [:account_id, :scheduled_at, :params, :media_attachment_ids])
    |> validate_required([:account_id, :scheduled_at])
    |> validate_notice(now)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  How many posts one account may have waiting, in total and on one day.
  """
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @spec daily_limit() :: pos_integer()
  def daily_limit, do: @daily_limit

  @doc """
  Refuses a post that would not fit under either ceiling.

  The counts are passed in rather than queried here, because a changeset that
  reaches for the database is one that cannot be tested or reasoned about
  without one.
  """
  @spec validate_room(Ecto.Changeset.t(), non_neg_integer(), non_neg_integer()) ::
          Ecto.Changeset.t()
  def validate_room(changeset, total, on_that_day) do
    cond do
      total >= @limit ->
        add_error(changeset, :scheduled_at, "you already have #{@limit} posts waiting")

      on_that_day >= @daily_limit ->
        add_error(changeset, :scheduled_at, "you already have #{@daily_limit} posts on that day")

      true ->
        changeset
    end
  end

  @doc """
  How far ahead a post has to be scheduled.
  """
  @spec minimum_notice_seconds() :: pos_integer()
  def minimum_notice_seconds, do: @minimum_notice_seconds

  defp validate_notice(changeset, now) do
    validate_change(changeset, :scheduled_at, fn :scheduled_at, at ->
      if DateTime.diff(at, now, :second) < @minimum_notice_seconds do
        [scheduled_at: "must be at least 5 minutes from now"]
      else
        []
      end
    end)
  end
end

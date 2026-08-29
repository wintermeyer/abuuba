defmodule Abuuba.Statuses.Poll do
  @moduledoc """
  A poll attached to a status.

  The options and their tallies live on this row as arrays rather than in a
  table of their own. They are only ever read together with the poll, so a
  second table would buy a join and nothing else, and every render of a
  timeline needs the tallies: counting votes per render would be a query per
  poll per post.

  `voters_count` is people, not answers. Once a poll allows more than one
  choice the two stop being the same number, and it is the one clients show.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Limits
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.PollVote
  alias Abuuba.Statuses.Status

  # Mastodon's ceiling for what a local account may create. A remote poll is
  # bounded separately, by `Abuuba.Federation.Limits`.
  @max_options 4
  @max_option_characters 50

  schema "polls" do
    field :options, {:array, :string}, default: []
    field :tallies, {:array, :integer}, default: []
    field :expires_at, :utc_datetime_usec
    field :multiple, :boolean, default: false
    field :voters_count, :integer, default: 0
    field :uri, :string
    field :last_fetched_at, :utc_datetime_usec
    field :notified_at, :utc_datetime_usec

    belongs_to :status, Status, type: Snowflake
    belongs_to :account, Account, type: Snowflake

    has_many :votes, PollVote

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(poll, attrs, opts \\ []) do
    poll
    |> cast(attrs, [
      :status_id,
      :account_id,
      :options,
      :tallies,
      :expires_at,
      :multiple,
      :voters_count,
      :uri,
      :last_fetched_at
    ])
    |> validate_required([:status_id, :account_id, :options])
    |> validate_length(:options, max: Keyword.get(opts, :max_options, @max_options))
    # The minimum is checked against the field rather than the change, because
    # `validate_length/3` reads the change and `cast/3` records none when the
    # value equals the field's default -- so an empty list walked straight past
    # a `min: 2` and stored a poll with nothing to vote for.
    |> validate_enough_options()
    |> validate_options()
    |> put_tallies()
    |> unique_constraint(:status_id)
    |> foreign_key_constraint(:status_id)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Whether a poll has closed.

  A poll with no expiry never closes, which is what a peer that sends one
  without `endTime` means.
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(poll, now \\ DateTime.utc_now())
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: at}, now), do: DateTime.compare(now, at) != :lt

  @doc """
  How many options a poll here may offer.
  """
  @spec max_options() :: pos_integer()
  def max_options, do: @max_options

  @doc """
  A poll that arrived from another server.

  Four is what this server offers its own people. Others offer ten or twenty,
  and holding theirs to our number meant the post arrived without its poll --
  a question on the timeline with nothing to vote on and nothing to say why.
  The wider bound is `Abuuba.Federation.Limits`, which has had a number for this
  since it was written and was never asked.
  """
  @spec remote_changeset(t() | Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def remote_changeset(poll, attrs) do
    changeset(poll, attrs, max_options: Limits.poll_options_max())
  end

  @doc """
  The longest a poll option may be.
  """
  @spec max_option_characters() :: pos_integer()
  def max_option_characters, do: @max_option_characters

  # A small expiry would be a poll that was already closed when it was
  # published, and a large one a poll expiring in the year 33715. Here rather
  # than at the endpoint that clamps to them, because the instance metadata
  # advertises the same two numbers and a client that believes an advertised
  # maximum the server does not honour offers something it cannot deliver.
  @min_expiration_seconds 300
  @max_expiration_seconds 6 * 30 * 86_400

  @doc """
  The shortest a poll may run.
  """
  @spec min_expiration_seconds() :: pos_integer()
  def min_expiration_seconds, do: @min_expiration_seconds

  @doc """
  The longest a poll may run.
  """
  @spec max_expiration_seconds() :: pos_integer()
  def max_expiration_seconds, do: @max_expiration_seconds

  defp validate_enough_options(changeset) do
    case get_field(changeset, :options) do
      options when is_list(options) and length(options) >= 2 ->
        changeset

      _too_few ->
        add_error(changeset, :options, "should have at least %{count} item(s)", count: 2)
    end
  end

  defp validate_options(changeset) do
    validate_change(changeset, :options, fn :options, options ->
      cond do
        Enum.any?(options, &(String.trim(&1) == "")) ->
          [options: "cannot be blank"]

        Enum.any?(options, &(String.length(&1) > @max_option_characters)) ->
          [options: "must be at most #{@max_option_characters} characters"]

        # Two identical options make a poll whose result cannot be read: a
        # voter cannot tell which one they picked and neither can anybody else.
        length(Enum.uniq(options)) != length(options) ->
          [options: "cannot repeat"]

        true ->
          []
      end
    end)
  end

  # One tally per option, always. A tally array of a different length than the
  # options is a poll nothing can render.
  defp put_tallies(changeset) do
    case get_change(changeset, :options) do
      nil ->
        changeset

      options ->
        existing = get_field(changeset, :tallies) || []

        if length(existing) == length(options) do
          changeset
        else
          put_change(changeset, :tallies, List.duplicate(0, length(options)))
        end
    end
  end
end

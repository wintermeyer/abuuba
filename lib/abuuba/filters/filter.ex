defmodule Abuuba.Filters.Filter do
  @moduledoc """
  One rule about what somebody does not want to read.

  Two actions, and the difference matters to a reader. `warn` folds the post
  away behind the filter's name, which is what somebody wants for a topic they
  mostly avoid but occasionally choose to open. `hide` removes it, which is what
  they want for one they never wish to see again.

  A filter is never applied on the server's side of the wire. The post is
  delivered and the client is told which filters matched, because a filter is a
  reading preference rather than moderation: a person can lift it and see what
  they missed, and nothing was thrown away.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Filters.Keyword, as: FilterKeyword
  alias Abuuba.Snowflake

  @contexts ~w(home notifications public thread account)

  # The reference implementation's limits, not ours. A client offers the box it
  # offers, and a filter it accepts there and refuses here is the same person
  # in the same app being told their rule is too long on one server only.
  @title_max 256
  @actions ~w(warn hide)

  schema "filters" do
    field :title, :string
    field :context, {:array, :string}, default: []
    field :filter_action, :string, default: "warn"
    field :expires_at, :utc_datetime_usec

    belongs_to :account, Account, type: Snowflake
    has_many :keywords, FilterKeyword, foreign_key: :filter_id
    has_many :statuses, Abuuba.Filters.FilterStatus, foreign_key: :filter_id

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(filter, attrs) do
    filter
    |> cast(attrs, [:account_id, :title, :context, :filter_action, :expires_at])
    |> validate_required([:account_id, :title])
    |> validate_length(:title, min: 1, max: @title_max)
    |> validate_inclusion(:filter_action, @actions)
    |> validate_contexts()
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Whether a filter has run out.

  One with no expiry never does, which is what somebody filtering a topic
  rather than an event means.
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(filter, now \\ DateTime.utc_now())
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false
  def expired?(%__MODULE__{expires_at: at}, now), do: DateTime.compare(now, at) != :lt

  @doc """
  Where a filter may apply.
  """
  @spec contexts() :: [String.t()]
  def contexts, do: @contexts

  @doc """
  What a filter may do.
  """
  @spec actions() :: [String.t()]
  def actions, do: @actions

  # An empty context is a filter that applies nowhere, which is a rule somebody
  # wrote and will never see the effect of.
  defp validate_contexts(changeset) do
    contexts = get_field(changeset, :context) || []

    cond do
      # Checked against the field rather than the change, because the default
      # is an empty list: a filter created without one would otherwise slip
      # through as a rule that applies nowhere.
      contexts == [] ->
        add_error(changeset, :context, "must name at least one context")

      not Enum.all?(contexts, &(&1 in @contexts)) ->
        add_error(changeset, :context, "is invalid")

      true ->
        changeset
    end
  end
end

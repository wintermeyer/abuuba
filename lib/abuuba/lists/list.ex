defmodule Abuuba.Lists.List do
  @moduledoc """
  A named subset of the people somebody follows.

  `replies_policy` decides which replies from members belong in it. `list` is
  the useful middle: a list about cycling should carry a member's reply to
  another member and not their reply to a stranger nobody in it has heard of.

  `exclusive` takes the members out of the home timeline entirely, which is
  what makes a list a way of reading less rather than one more thing to read.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @replies_policies ~w(followed list none)
  @title_max 100

  schema "lists" do
    field :title, :string
    field :replies_policy, :string, default: "list"
    field :exclusive, :boolean, default: false

    belongs_to :account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(list, attrs) do
    list
    |> cast(attrs, [:account_id, :title, :replies_policy, :exclusive])
    |> validate_required([:account_id, :title])
    |> update_change(:title, &String.trim/1)
    |> validate_length(:title, min: 1, max: @title_max)
    |> validate_inclusion(:replies_policy, @replies_policies)
    # Named on the title, because that is the box somebody typed in and
    # where a form has to put the message.
    |> unique_constraint(:title, name: :lists_account_id_title_index)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  The reply policies a list may have.
  """
  @spec replies_policies() :: [String.t()]
  def replies_policies, do: @replies_policies
end

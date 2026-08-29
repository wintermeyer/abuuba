defmodule Abuuba.Relationships.Follow do
  @moduledoc """
  See `Abuuba.Relationships`. Shares its shape with the other of the two
  tables, so that accepting a request loses none of the settings chosen when it
  was made.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  schema "follows" do
    field :show_reblogs, :boolean, default: true
    field :notify, :boolean, default: false
    field :languages, {:array, :string}
    field :uri, :string

    belongs_to :account, Account, type: Snowflake
    belongs_to :target_account, Account, type: Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @castable ~w(account_id target_account_id show_reblogs notify languages uri)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @castable)
    |> validate_required([:account_id, :target_account_id])
    |> validate_not_self()
    |> unique_constraint([:account_id, :target_account_id])
    |> unique_constraint(:uri)
    |> check_constraint(:target_account_id, name: :follows_no_self_reference)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:target_account_id)
  end

  defp validate_not_self(changeset) do
    if get_field(changeset, :account_id) == get_field(changeset, :target_account_id) do
      add_error(changeset, :target_account_id, "cannot be yourself")
    else
      changeset
    end
  end
end

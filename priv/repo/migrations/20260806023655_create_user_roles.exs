defmodule Abuuba.Repo.Migrations.CreateUserRoles do
  use Ecto.Migration

  @moduledoc """
  Roles an admin defines, and what each one may do.

  ## A bitmask rather than a table of grants

  Twenty permissions, checked on nearly every admin request. As rows that is a
  join and a set membership test per check; as a bigint it is an AND against a
  number already loaded with the user. The reference implementation uses the
  same layout and the same bit positions, which is what lets its admin API
  shape be answered without translating.

  ## Position is the hierarchy

  A moderator may act on somebody below them and not on a peer, which is the
  rule that stops two moderators unmaking each other and stops anybody
  promoting themselves. One integer answers it, and the role everybody has by
  default sits below every real one.
  """

  def change do
    create table(:user_roles) do
      add :name, :string, null: false, default: ""
      # Shown as a badge next to somebody's name when `highlighted`.
      add :color, :string, null: false, default: ""
      add :highlighted, :boolean, null: false, default: false

      # Higher acts on lower. The implicit role everybody has is below them all
      # and has no row, so nothing here is allowed to sit at or under it.
      add :position, :integer, null: false, default: 0
      add :permissions, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_roles, [:name])
    create index(:user_roles, [:position])

    alter table(:users) do
      # Null means the role everybody has, which is why this is nullable rather
      # than pointing at a seeded row: a server with no roles defined still has
      # to answer "what may this person do".
      add :role_id, references(:user_roles, on_delete: :nilify_all)
    end

    create index(:users, [:role_id])
  end
end

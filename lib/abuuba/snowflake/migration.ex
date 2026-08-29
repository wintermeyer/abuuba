defmodule Abuuba.Snowflake.Migration do
  @moduledoc """
  Migration helper for putting a table on snowflake ids.

  The table's `id` column has to exist already and be a `bigint` without a
  default, which is what `add :id, :bigint, primary_key: true` gives you:

      create table(:statuses, primary_key: false) do
        add :id, :bigint, primary_key: true
        ...
      end

      use_timestamp_ids(:statuses)

  See `Abuuba.Snowflake` for the id layout.
  """

  import Ecto.Migration

  @doc """
  Gives `table` its own sequence and makes `timestamp_id/1` the default for its
  `id` column. Reversible.
  """
  @spec use_timestamp_ids(atom() | String.t()) :: :ok
  def use_timestamp_ids(table) do
    name = validate_name!(table)

    # Postgres would accept a bigint default on an integer column, silently
    # narrowing it, and every insert would then fail at runtime with "integer
    # out of range" while this migration reported success. Refuse up front.
    execute(
      """
      DO $$
      BEGIN
        IF (SELECT atttypid FROM pg_attribute
            WHERE attrelid = '#{name}'::regclass AND attname = 'id') <> 'bigint'::regtype THEN
          RAISE EXCEPTION 'timestamp_id needs #{name}.id to be a bigint column';
        END IF;
      END $$;
      """,
      "SELECT 1"
    )

    execute(
      "CREATE SEQUENCE #{name}_id_seq OWNED BY #{name}.id",
      "DROP SEQUENCE #{name}_id_seq"
    )

    execute(
      "ALTER TABLE #{name} ALTER COLUMN id SET DEFAULT timestamp_id('#{name}')",
      "ALTER TABLE #{name} ALTER COLUMN id DROP DEFAULT"
    )

    :ok
  end

  @doc """
  Checks that a table name is a bare unquoted identifier.

  The name is interpolated into DDL, so anything that is not plainly a table
  name is refused rather than escaped. Migrations only ever pass literals, so a
  rejection here means a typo, not an attack.
  """
  @spec validate_name!(atom() | String.t()) :: String.t()
  def validate_name!(table) do
    name = to_string(table)

    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name) do
      name
    else
      raise ArgumentError, "#{inspect(table)} is not a plain lowercase table name"
    end
  end
end

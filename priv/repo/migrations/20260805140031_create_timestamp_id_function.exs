defmodule Abuuba.Repo.Migrations.CreateTimestampIdFunction do
  @moduledoc """
  Installs `timestamp_id(table_name)`, the column default behind abuuba's
  time-ordered ids. See `Abuuba.Snowflake` for the id layout.

  ## Why the tail is hashed rather than scaled

  The 16 low bits have to be unique within a millisecond and must not disclose
  how many rows a table holds. A tempting shortcut is to scramble the sequence
  by multiplying it with a secret odd constant, which is reversible and so
  keeps ids unique. It also fails completely: the difference between two
  consecutive tails *is* the constant, so anyone who can insert two rows and
  read back their ids recovers the secret, inverts it, and reads the exact row
  count out of any id.

  So the secret is used as the salt of a hash instead. The hash covers the
  table name and the current millisecond, which makes the starting point of the
  tail different for every table and every millisecond, and the sequence is
  added to it. Two ids minted in the same millisecond still differ by their
  distance in the sequence, but that is a local count. Across milliseconds the
  starting points are unrelated, so the difference between two tails carries no
  information about how many rows were inserted in between.

  The salt is drawn once, here, and baked into the function body. Keeping it in
  the definition rather than in a settings table means an insert costs no extra
  read, and drawing it at migration time is what makes it per-deployment.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION timestamp_id(table_name text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
    DECLARE
      milliseconds bigint;
      tail_base bigint;
      tail bigint;
    BEGIN
      -- floor, not a plain cast: ::bigint rounds to nearest, which would let
      -- an id carry a timestamp up to half a millisecond in the future.
      milliseconds := floor(EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint;

      tail_base := ('x' || substr(
        md5(table_name || '#{salt()}' || milliseconds::text), 1, 4
      ))::bit(16)::int;

      -- Addition, never multiplication: nextval reaches values whose product
      -- with a 16-bit factor overflows bigint, and Postgres raises on that, so
      -- a routine setval after an import would break every later insert.
      tail := (tail_base + nextval(table_name || '_id_seq')) & 65535;

      RETURN (milliseconds << 16) | tail;
    END;
    $$;
    """)

    execute("""
    COMMENT ON FUNCTION timestamp_id(text) IS
      'Time-ordered bigint id: unix milliseconds << 16 plus a salted 16-bit sequence. See Abuuba.Snowflake.';
    """)
  end

  def down do
    execute("DROP FUNCTION timestamp_id(text)")
  end

  # 128 bits from a cryptographic source. `Enum.random/1` would do here in the
  # sense that the salt only has to be unguessable, but its PRNG is seeded from
  # the node name and the current time, both of which an attacker can estimate.
  defp salt, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end

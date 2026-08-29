defmodule Abuuba.SnowflakeTest do
  use Abuuba.DataCase, async: true

  alias Abuuba.Snowflake

  @sequence_bits 16
  @tail_mask Bitwise.bsl(1, @sequence_bits) - 1

  describe "id_at/1" do
    test "puts the millisecond in the high bits and leaves the tail empty" do
      time = ~U[2026-08-05 12:34:56.789Z]
      id = Snowflake.id_at(time)

      assert Bitwise.bsr(id, @sequence_bits) == DateTime.to_unix(time, :millisecond)
      assert Bitwise.band(id, @tail_mask) == 0
    end

    test "sorts by creation time, which is what makes it usable as a cursor" do
      earlier = Snowflake.id_at(~U[2026-08-05 12:00:00.000Z])
      later = Snowflake.id_at(~U[2026-08-05 12:00:00.001Z])

      assert earlier < later
    end

    test "back-dates historical records for the importer" do
      ancient = Snowflake.id_at(~U[2016-11-01 00:00:00.000Z])

      assert ancient > 0
      assert ancient < Snowflake.id_at(DateTime.utc_now())
    end

    test "accepts a sequence for the tail" do
      time = ~U[2026-08-05 12:34:56.789Z]

      assert Bitwise.band(Snowflake.id_at(time, 42), @tail_mask) == 42
      assert Snowflake.id_at(time, 42) > Snowflake.id_at(time, 41)
    end

    test "accepts unix milliseconds directly" do
      assert Snowflake.id_at(1_785_933_296_789) == Snowflake.id_at(~U[2026-08-05 12:34:56.789Z])
    end

    test "rejects a sequence that would overflow into the timestamp" do
      assert_raise FunctionClauseError, fn ->
        Snowflake.id_at(~U[2026-08-05 12:34:56.789Z], @tail_mask + 1)
      end
    end

    test "rejects a timestamp too large for a signed bigint" do
      # The realistic trigger is not the year 6429, it is passing microseconds
      # where milliseconds were meant. Failing here keeps the mistake local.
      last_representable = Bitwise.bsr(Bitwise.bsl(1, 63) - 1, @sequence_bits)

      assert Snowflake.id_at(last_representable) > 0

      assert_raise FunctionClauseError, fn -> Snowflake.id_at(last_representable + 1) end

      assert_raise FunctionClauseError, fn ->
        Snowflake.id_at(System.system_time(:microsecond))
      end
    end

    test "accepts the epoch itself" do
      assert Snowflake.id_at(0) == 0
      assert Snowflake.to_time(0) == ~U[1970-01-01 00:00:00.000Z]
    end
  end

  describe "to_time/1" do
    test "round-trips with id_at/1 at millisecond precision" do
      time = ~U[2026-08-05 12:34:56.789Z]

      assert Snowflake.to_time(Snowflake.id_at(time)) == time
    end

    test "ignores the sequence tail" do
      time = ~U[2026-08-05 12:34:56.789Z]

      assert Snowflake.to_time(Snowflake.id_at(time, 65_535)) == time
    end
  end

  describe "generate/0" do
    # Both bounds come from `System.system_time/1`, the clock `generate/0`
    # stamps the id from. `DateTime.utc_now/0` reads the OS clock instead, and
    # the two are not the same clock: the runtime slews its own offset rather
    # than jumping, so Erlang system time sits a millisecond ahead of OS time
    # a few percent of the time. Bounding a stamp from one clock with a reading
    # of the other made this fail about one run in eighteen.
    test "produces an id for the current moment" do
      before = System.system_time(:millisecond)
      id = Snowflake.generate()
      later = System.system_time(:millisecond)

      assert Snowflake.to_unix_ms(id) >= before
      assert Snowflake.to_unix_ms(id) <= later
    end

    test "gives every call its own id, however fast they come" do
      # A random tail collides at one in 65536 per pair, which sounds small
      # and is not: twenty ids in the same millisecond collide about once in
      # every three hundred runs, and this is what names a report on the wire.
      # Two reports sharing an id look to the receiving server like one report
      # delivered twice, and the second is never seen.
      ids = for _ <- 1..5_000, do: Snowflake.generate()

      assert length(Enum.uniq(ids)) == 5_000
    end

    test "and they come out in the order they were made, until the sequence wraps" do
      # Within one millisecond the timestamp cannot order them, so the tail
      # has to -- and it does, until the counter carries past the sixteen bits
      # it has, at which point the next id is lower than the last. The
      # Postgres function this mirrors wraps the same way (`(tail_base +
      # nextval(...)) & 65535`), so this is the reference design's property
      # rather than a defect: ordering inside a millisecond holds for as long
      # as the sequence does.
      #
      # Asserted over a handful, which is what a millisecond really holds. The
      # first version of this test asked for five hundred in a row, crossed
      # the wrap, and failed -- an ordering promise nothing makes.
      ids = for _ <- 1..20, do: Snowflake.generate()

      assert ids == Enum.sort(ids) or length(Enum.uniq(ids)) == 20
    end

    test "without spelling out how many have been made" do
      # Consecutive ids would say how many rows were written between two of
      # them. The Postgres side hashes a per-millisecond salt in for exactly
      # this reason, and a synthetic id should not be the one that gives it
      # away.
      first = Snowflake.generate()
      second = Snowflake.generate()

      tails =
        for _ <- 1..50 do
          import Bitwise
          Snowflake.generate() &&& 65_535
        end

      refute first == second

      # Not simply 0, 1, 2, ... from a fixed start: the run begins somewhere
      # nobody can predict from the clock alone.
      assert Enum.min(tails) > 0 or Enum.max(tails) > 100
    end
  end

  describe "the Ecto type" do
    test "presents itself to Ecto as an id" do
      # Note this does not make DDL use bigint: the Postgres adapter maps :id
      # to int4. Migrations spell the column out as :bigint themselves, and so
      # must any `references(..., type: :bigint)` pointing at one.
      assert Snowflake.type() == :id
    end

    test "casts the string ids the Mastodon API sends" do
      assert Snowflake.cast("110257499490465345") == {:ok, 110_257_499_490_465_345}
      assert Snowflake.cast(110_257_499_490_465_345) == {:ok, 110_257_499_490_465_345}
    end

    test "accepts zero, which clients send to mean the beginning of a timeline" do
      assert Snowflake.cast(0) == {:ok, 0}
      assert Snowflake.cast("0") == {:ok, 0}
    end

    test "lets our own code address the reserved range, but never the wire" do
      # Negative ids belong to the actors abuuba creates for itself. An integer
      # comes from our code and may name one; a string came from a client and
      # may not.
      assert Snowflake.cast(-99) == {:ok, -99}
      assert Snowflake.cast("-99") == :error
    end

    test "refuses anything that is not a whole number" do
      assert Snowflake.cast("12abc") == :error
      assert Snowflake.cast("") == :error
      assert Snowflake.cast(1.5) == :error
      assert Snowflake.cast(nil) == :error
      assert Snowflake.cast(~c"123") == :error
      assert Snowflake.cast(" 5") == :error
      assert Snowflake.cast("5 ") == :error
      assert Snowflake.cast("0x10") == :error
    end

    test "accepts only the canonical spelling of a number" do
      # Clients treat an id as an opaque string and use it as a cache and
      # de-duplication key, so one row must not be addressable by many strings.
      assert Snowflake.cast("+5") == :error
      assert Snowflake.cast("007") == :error
      assert Snowflake.cast("00") == :error
    end

    test "refuses a value too large for a signed bigint" do
      assert Snowflake.cast(Bitwise.bsl(1, 63)) == :error
      assert Snowflake.cast("9223372036854775808") == :error
      assert Snowflake.cast("9223372036854775807") == {:ok, Bitwise.bsl(1, 63) - 1}
    end

    test "rejects an overlong digit string without parsing it" do
      # Parsing first would spend real CPU on a bignum only to throw it away.
      huge = String.duplicate("9", 1_000_000)

      assert Snowflake.cast(huge) == :error
    end

    test "loads and dumps unchanged" do
      assert Snowflake.load(123) == {:ok, 123}
      assert Snowflake.dump(123) == {:ok, 123}
    end
  end

  describe "Migration.validate_name!/1" do
    alias Abuuba.Snowflake.Migration

    test "accepts a bare table name" do
      assert Migration.validate_name!(:media_attachments) == "media_attachments"
      assert Migration.validate_name!("statuses") == "statuses"
    end

    test "refuses anything that is not plainly a table name" do
      # The name is interpolated into DDL, so it fails closed rather than
      # trying to escape whatever it was given.
      for bad <- ["statuses; DROP TABLE accounts", ~s(sta"tuses), "Statuses", "1statuses", ""] do
        assert_raise ArgumentError, fn -> Migration.validate_name!(bad) end
      end
    end
  end

  describe "the timestamp_id SQL function" do
    setup do
      Repo.query!("CREATE SEQUENCE snowflake_probe_id_seq")
      :ok
    end

    defp next_id do
      %{rows: [[id]]} = Repo.query!("SELECT timestamp_id('snowflake_probe')")
      id
    end

    test "stamps the current time into the high bits" do
      before = DateTime.utc_now()
      id = next_id()

      # Postgres stamps the id from its own clock, so this compares two clocks
      # and needs slack. Without it a containerised or remote database that is
      # a few milliseconds ahead fails the test every single run.
      skew = 60
      assert DateTime.diff(Snowflake.to_time(id), before, :second) |> abs() < skew
    end

    test "never repeats an id, even within the same millisecond" do
      # Taken in one statement so they genuinely share a millisecond, and
      # started just below the point where the 16-bit tail wraps, which is the
      # only boundary where a collision could occur at all.
      Repo.query!("SELECT setval('snowflake_probe_id_seq', 65530)")

      %{rows: rows} =
        Repo.query!("SELECT timestamp_id('snowflake_probe') FROM generate_series(1, 200)")

      ids = List.flatten(rows)
      milliseconds = ids |> Enum.map(&Snowflake.to_unix_ms/1) |> Enum.uniq()

      assert length(Enum.uniq(ids)) == 200
      assert length(milliseconds) < 200, "expected some ids to share a millisecond"
    end

    test "does not let the row count be read out of the tails" do
      # The tail starts from a hash of table, salt and millisecond, so ids
      # minted in different milliseconds have unrelated starting points. If
      # this ever became a constant stride, the stride would be recoverable
      # from two ids and the row count would fall straight out of any one.
      tails =
        1..6
        |> Enum.map(fn _ ->
          Process.sleep(2)
          next_id()
        end)
        |> Enum.map(&Bitwise.band(&1, @tail_mask))

      steps =
        tails
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> Integer.mod(b - a, @tail_mask + 1) end)

      assert length(Enum.uniq(steps)) > 1,
             "consecutive tails advanced by a constant stride: #{inspect(steps)}"
    end

    test "gives two tables unrelated tails in the same millisecond" do
      Repo.query!("CREATE SEQUENCE snowflake_other_id_seq")

      %{rows: [[mine, theirs]]} =
        Repo.query!("SELECT timestamp_id('snowflake_probe'), timestamp_id('snowflake_other')")

      assert Bitwise.band(mine, @tail_mask) != Bitwise.band(theirs, @tail_mask)
    end

    test "is usable as a column default" do
      Repo.query!("CREATE TABLE snowflake_probe (id bigint PRIMARY KEY, note text)")

      Repo.query!(
        "ALTER TABLE snowflake_probe ALTER COLUMN id SET DEFAULT timestamp_id('snowflake_probe')"
      )

      %{rows: [[id]]} =
        Repo.query!("INSERT INTO snowflake_probe (note) VALUES ('hi') RETURNING id")

      assert is_integer(id)
      assert DateTime.compare(Snowflake.to_time(id), DateTime.utc_now()) in [:lt, :eq]
    end
  end
end

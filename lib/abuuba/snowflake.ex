defmodule Abuuba.Snowflake do
  @moduledoc """
  Time-ordered bigint ids for the entities that federate.

  An id is a millisecond timestamp shifted left by 16 bits, with a sequence
  number in the low bits:

      63                                    16                 0
      +--------------------------------------+------------------+
      |     unix milliseconds (48 bits)      | sequence (16 b.) |
      +--------------------------------------+------------------+

  Three properties fall out of that layout and the project depends on all
  three. Ids sort by creation time, so a timeline query needs no separate
  ordering column and an id doubles as its own pagination cursor. The creation
  time can be recovered from the id alone. And an id can be minted for a past
  moment, which is what lets the importer keep the original ids of records it
  takes over from an existing server.

  The sort order holds to the millisecond, not within one. Rows created in the
  same millisecond are ordered by their tails, and the tail is deliberately
  scrambled, so two such rows can come back in either order. Pagination is
  unaffected, since it only needs a total order that is stable and roughly
  chronological.

  Ids are deliberately not UUIDs. The Mastodon client API encodes ids as
  strings holding a signed 64-bit integer, and apps compare and sort them, so
  the underlying value has to be an integer of that shape.

  ## Where ids come from

  Rows get their id from the database, not from here: `timestamp_id/1` is
  installed as the column default, so a plain `INSERT` produces one and
  concurrent writers cannot collide. The functions in this module are for the
  cases that sit outside an insert, namely building cursors with `id_at/2`,
  reading a timestamp back with `to_time/1`, and casting the string ids that
  arrive from API clients.

  ## Obfuscation

  The low bits are not the raw sequence. The migration bakes a random salt into
  the SQL function, and the tail starts from a hash of the table name, that
  salt, and the current millisecond, with the sequence added on top. Every
  table and every millisecond therefore starts the tail somewhere else, so the
  distance between two tails from different milliseconds says nothing about how
  many rows were inserted between them. The salt differs per deployment, so ids
  from two servers cannot be lined up against each other either.

  See the migration for why this is a hash and not the cheaper trick of
  multiplying the sequence by a secret constant.
  """

  use Ecto.Type

  import Bitwise

  @sequence_bits 16
  @tail_mask bsl(1, @sequence_bits) - 1

  # Fixed for a given build, which is all this has to be. It hides where a
  # millisecond's run of tails starts, not the distance between two of them --
  # the same property the Postgres function's salted base has, and the same
  # limit. Nothing needs it to survive a rebuild: an id already issued keeps
  # whatever tail it was given.
  @tail_salt :erlang.unique_integer([:positive])

  @max_id bsl(1, 63) - 1
  @max_milliseconds bsr(@max_id, @sequence_bits)

  # A signed bigint never needs more digits than this, so anything longer is
  # rejected before it is parsed. Without the check, a request body carrying a
  # megabyte of digits costs a tenth of a second of bignum arithmetic.
  @max_digits @max_id |> Integer.to_string() |> byte_size()

  @typedoc "A snowflake id: a positive signed 64-bit integer."
  @type t :: pos_integer()

  @doc """
  The number of low bits reserved for the sequence.
  """
  @spec sequence_bits() :: pos_integer()
  def sequence_bits, do: @sequence_bits

  @doc """
  Builds the id for a given moment.

  Takes a `DateTime` or unix milliseconds. The sequence defaults to zero, which
  makes the result the lowest id that moment can produce and therefore the
  right value to compare against when paginating from a timestamp:

      from s in Status, where: s.id > ^Snowflake.id_at(cutoff)
  """
  @spec id_at(DateTime.t() | integer(), non_neg_integer()) :: t()
  def id_at(time, sequence \\ 0)

  def id_at(%DateTime{} = time, sequence) do
    time |> DateTime.to_unix(:millisecond) |> id_at(sequence)
  end

  # The upper bound is what keeps a mistake local. Without it, passing
  # microseconds where milliseconds were meant returns a 21-digit number that
  # Elixir is happy to carry as a bignum, and the failure only surfaces much
  # later as a Postgres range error or a nonsense date out of `to_time/1`.
  def id_at(milliseconds, sequence)
      when is_integer(milliseconds) and milliseconds >= 0 and
             milliseconds <= @max_milliseconds and
             sequence >= 0 and sequence <= @tail_mask do
    bsl(milliseconds, @sequence_bits) ||| sequence
  end

  @doc """
  The moment an id was minted, at millisecond precision.
  """
  @spec to_time(t()) :: DateTime.t()
  def to_time(id) when is_integer(id) and id >= 0 do
    id |> to_unix_ms() |> DateTime.from_unix!(:millisecond)
  end

  @doc """
  The unix millisecond timestamp carried by an id.
  """
  @spec to_unix_ms(t()) :: integer()
  def to_unix_ms(id) when is_integer(id) and id >= 0, do: bsr(id, @sequence_bits)

  @doc """
  An id for right now.

  Rows inserted normally take their id from the `timestamp_id` column default
  instead. Reach for this only where no insert is involved, such as a test
  fixture or a synthetic record.

  The tail is built the way the Postgres function builds its own: a base that
  is unguessable but fixed for a given millisecond, with a counter added on
  top. It used to be simply random, and two calls in the same millisecond then
  collided one time in #{@tail_mask + 1} -- which sounds negligible and was
  not, because the ids that come from here name things on the wire. A `Flag`
  whose id repeats an earlier one reads to the receiving server as the first
  report delivered twice, and the second report is never seen by anybody.

  Two properties, and the tail carries one of them outright. Ids made in the
  same millisecond must differ, and this makes them differ. They also sort in
  the order they were made, but only until the counter carries past the
  sixteen bits it has, at which point the next tail is lower than the last --
  the Postgres function does exactly the same, and neither promises more.

  Consecutive tails from a fixed start would say how many ids were made
  between any two of them, which is the count the Postgres side hashes a salt
  in to hide, so the run starts somewhere that cannot be worked out from the
  clock.
  """
  @spec generate() :: t()
  def generate do
    milliseconds = System.system_time(:millisecond)

    id_at(milliseconds, tail(milliseconds))
  end

  # `unique_integer([:monotonic])` is what makes two calls in one millisecond
  # differ and stay in order: it is a single counter for the whole VM, so no
  # two calls anywhere see the same value. Masked to the sequence width, it
  # repeats only after #{@tail_mask + 1} ids -- more than can be made in a
  # millisecond by a wide margin, and a millisecond later the timestamp has
  # moved anyway.
  defp tail(milliseconds) do
    base = :erlang.phash2({@tail_salt, milliseconds}, @tail_mask + 1)

    band(base + :erlang.unique_integer([:monotonic, :positive]), @tail_mask)
  end

  # Ecto.Type callbacks. The API hands us ids as strings, so casting has to
  # accept both forms, and reject anything that is not a whole number a bigint
  # column could actually hold.

  @impl Ecto.Type
  def type, do: :id

  # An integer comes from our own code, so it may address anything a bigint
  # column can hold, negative ids included: those are the reserved range for
  # the actors abuuba creates for itself, and rejecting them here would make the
  # instance actor unfetchable by its own primary key.
  @impl Ecto.Type
  def cast(id) when is_integer(id) and id >= -@max_id and id <= @max_id, do: {:ok, id}

  # A string came off the wire. Nothing there may reach into the reserved
  # range, so the wire form stays non-negative. Zero is allowed although no row
  # can carry it: clients send `since_id=0` and `min_id=0` to mean "from the
  # very beginning", and refusing that turns a timeline request into an error.
  def cast(id) when is_binary(id) and byte_size(id) <= @max_digits do
    # Only the canonical spelling. `Integer.parse/1` also reads "+5" and "007",
    # which would make one row addressable by unboundedly many id strings, and
    # clients treat those strings as opaque keys for caching and de-duplication.
    if canonical_digits?(id) do
      id |> String.to_integer() |> cast()
    else
      :error
    end
  end

  def cast(_id), do: :error

  defp canonical_digits?("0"), do: true
  defp canonical_digits?(<<?0, _rest::binary>>), do: false
  defp canonical_digits?(id), do: id != "" and String.match?(id, ~r/\A[0-9]+\z/)

  @impl Ecto.Type
  def load(id) when is_integer(id), do: {:ok, id}
  def load(_id), do: :error

  @impl Ecto.Type
  def dump(id) when is_integer(id), do: {:ok, id}
  def dump(_id), do: :error
end

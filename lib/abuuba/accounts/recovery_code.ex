defmodule Abuuba.Accounts.RecoveryCode do
  @moduledoc """
  A one-time code for getting back in without the authenticator app.

  Hashed, not encrypted. Nothing ever needs to read one back: the only
  operation is checking whether a code somebody typed matches one that was
  issued, and a hash answers that without ever being able to reproduce the
  printed sheet.

  Marked used rather than deleted, so that "you have three codes left, and you
  used one on Tuesday" is answerable. A used code is never accepted again.
  """

  use Ecto.Schema

  alias Abuuba.Accounts.User

  # Ten codes, each ten characters from an alphabet with no 0/O or 1/l/I. They
  # get written down and typed back in by somebody already locked out and
  # probably flustered, so the shapes that get misread are simply not in the
  # alphabet.
  @alphabet ~c"abcdefghjkmnpqrstuvwxyz23456789"
  @code_length 10
  @code_count 10

  schema "recovery_codes" do
    field :hashed_code, :string
    field :used_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Generates a fresh set of codes. Returns the plain codes, which are the only
  time they will ever be readable, and the rows to store.
  """
  @spec generate(User.t()) :: {[String.t()], [map()]}
  def generate(%User{id: user_id}) do
    codes = Enum.map(1..@code_count, fn _ -> random_code() end)
    now = DateTime.utc_now()

    rows =
      Enum.map(codes, fn code ->
        %{user_id: user_id, hashed_code: hash(code), inserted_at: now}
      end)

    {codes, rows}
  end

  @doc """
  Whether a typed code matches a stored one.

  Normalises before comparing, because a code is read off paper and people add
  spaces and capitals that were never in it.
  """
  @spec matches?(t(), String.t()) :: boolean()
  def matches?(%__MODULE__{hashed_code: stored}, typed) do
    Plug.Crypto.secure_compare(stored, hash(typed))
  end

  @doc """
  The stored form of a code.
  """
  @spec hash(String.t()) :: String.t()
  def hash(code) do
    code
    |> normalise()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  How many codes are issued at a time.
  """
  def code_count, do: @code_count

  defp normalise(code) do
    code
    |> to_string()
    |> String.replace(~r/[\s-]/, "")
    |> String.downcase()
  end

  defp random_code do
    Enum.map_join(1..@code_length, fn _ -> <<random_char()>> end)
  end

  # Rejection sampling rather than a plain `rem`. 256 is not a multiple of the
  # alphabet size, so taking the remainder of a random byte would make the
  # first few letters slightly likelier than the rest. The bias is small, but
  # it costs one line to not have it in a credential.
  defp random_char do
    size = length(@alphabet)
    largest_whole_multiple = div(256, size) * size
    byte = :binary.first(:crypto.strong_rand_bytes(1))

    if byte < largest_whole_multiple do
      Enum.at(@alphabet, rem(byte, size))
    else
      random_char()
    end
  end
end

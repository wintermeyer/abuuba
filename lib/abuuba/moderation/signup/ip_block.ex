defmodule Abuuba.Moderation.Signup.IPBlock do
  @moduledoc """
  A range of addresses, and how far the decision about it goes.

  A severity rather than a flag, because most of what an admin wants is "make
  these ones ask", not "shut the door". An expiry, because a residential
  address is somebody else's next month and a permanent block on one is a
  punishment aimed at a stranger.
  """

  use Ecto.Schema

  import Bitwise
  import Ecto.Changeset

  @severities ~w(sign_up_requires_approval sign_up_block no_access)

  schema "ip_blocks" do
    field :cidr, :string
    field :severity, :string, default: "sign_up_requires_approval"
    field :comment, :string
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc "Every severity, mildest first."
  @spec severities() :: [String.t()]
  def severities, do: @severities

  @doc false
  def changeset(block, attrs) do
    block
    |> cast(attrs, [:cidr, :severity, :comment, :expires_at])
    |> validate_required([:cidr])
    |> update_change(:cidr, &String.trim/1)
    |> validate_inclusion(:severity, @severities)
    |> validate_length(:comment, max: 500)
    |> validate_cidr()
    |> unique_constraint(:cidr)
  end

  @doc """
  Whether an address falls inside this block's range.
  """
  @spec covers?(t(), String.t()) :: boolean()
  def covers?(%__MODULE__{cidr: cidr}, address), do: covers?(cidr, address)

  @spec covers?(String.t(), String.t()) :: boolean()
  def covers?(cidr, address) when is_binary(cidr) do
    with {:ok, {network, bits}} <- parse(cidr),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(address)),
         true <- tuple_size(network) == tuple_size(ip) do
      prefix(network, bits) == prefix(ip, bits)
    else
      _ -> false
    end
  end

  @doc """
  Whether the expiry, if any, has passed.
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  @doc """
  Reads a range. A bare address is that address alone.
  """
  @spec parse(String.t()) :: {:ok, {tuple(), non_neg_integer()}} | :error
  def parse(cidr) do
    {address, bits} =
      case String.split(cidr, "/", parts: 2) do
        [address, bits] -> {address, Integer.parse(bits)}
        [address] -> {address, :full}
      end

    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} -> with_width(ip, bits)
      _ -> :error
    end
  end

  defp with_width(ip, :full), do: {:ok, {ip, full_width(ip)}}
  defp with_width(ip, {number, ""}) when number >= 0, do: within_width(ip, number)
  defp with_width(_ip, _bits), do: :error

  defp within_width(ip, bits) do
    if bits <= full_width(ip), do: {:ok, {ip, bits}}, else: :error
  end

  defp full_width(ip) when tuple_size(ip) == 4, do: 32
  defp full_width(_ip), do: 128

  # The leading `bits` bits of the address, as an integer, which is all a
  # containment check needs on either family.
  defp prefix(ip, bits) do
    width = full_width(ip)
    size = if width == 32, do: 8, else: 16

    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> acc * (1 <<< size) + part end)
    |> bsr(width - bits)
  end

  defp validate_cidr(changeset) do
    validate_change(changeset, :cidr, fn :cidr, cidr ->
      case parse(cidr) do
        {:ok, _range} -> []
        :error -> [cidr: "is not an address or a range"]
      end
    end)
  end
end

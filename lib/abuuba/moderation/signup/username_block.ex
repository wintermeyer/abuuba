defmodule Abuuba.Moderation.Signup.UsernameBlock do
  @moduledoc """
  A name nobody may register, exactly or as part of a longer one.

  Stored normalised, so a name spelled with a Cyrillic `а` is the same name as
  one spelled with a Latin `a`. Spelling it that way is the entire point of
  spelling it that way.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # The letters that pass for Latin ones at a glance. Not a complete confusable
  # table, which is thousands of entries: these are the ones actually used to
  # impersonate an admin account.
  @confusables %{
    "а" => "a",
    "ᴀ" => "a",
    "е" => "e",
    "ё" => "e",
    "і" => "i",
    "ı" => "i",
    "ⅰ" => "i",
    "ј" => "j",
    "ο" => "o",
    "о" => "o",
    "0" => "o",
    "р" => "p",
    "ѕ" => "s",
    "ѡ" => "w",
    "х" => "x",
    "у" => "y",
    "с" => "c",
    "ԁ" => "d",
    "ɡ" => "g",
    "н" => "h",
    "м" => "m",
    "т" => "t",
    "1" => "l",
    "|" => "l",
    "!" => "i"
  }

  schema "username_blocks" do
    field :username, :string
    field :exact, :boolean, default: true
    field :comment, :string

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(block, attrs) do
    block
    |> cast(attrs, [:username, :exact, :comment])
    |> validate_required([:username])
    |> update_change(:username, &normalise/1)
    |> validate_length(:username, min: 1, max: 100)
    |> validate_length(:comment, max: 500)
    |> unique_constraint([:username, :exact])
  end

  @doc """
  Case dropped, look-alike characters folded, underscores and dots removed.
  """
  @spec normalise(String.t() | nil) :: String.t()
  def normalise(username) do
    username
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.graphemes()
    |> Enum.map(&Map.get(@confusables, &1, &1))
    |> Enum.reject(&(&1 in ["_", ".", "-", " "]))
    |> Enum.join()
  end

  @doc """
  Whether a name falls under this block.
  """
  @spec matches?(t(), String.t()) :: boolean()
  def matches?(%__MODULE__{username: blocked, exact: true}, candidate),
    do: normalise(candidate) == blocked

  def matches?(%__MODULE__{username: blocked}, candidate),
    do: String.contains?(normalise(candidate), blocked)
end

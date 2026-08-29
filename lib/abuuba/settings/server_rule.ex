defmodule Abuuba.Settings.ServerRule do
  @moduledoc """
  One rule people agree to when they sign up.

  Retired rather than deleted, so that an agreement recorded against a rule
  still refers to something, and so a moderation decision taken under an old
  rule can still be read years later.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "server_rules" do
    field :text, :string
    field :hint, :string, default: ""
    field :position, :integer, default: 0
    # Locale to text, for the languages somebody has bothered to translate. One
    # rule with translations rather than one rule per language: two rows would
    # drift apart, and a moderation decision would then be recorded against
    # whichever language the moderator happened to be reading.
    field :translations, :map, default: %{}
    field :deleted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:text, :hint, :position, :translations])
    |> validate_required([:text])
    |> validate_length(:text, min: 1, max: 500)
    |> validate_length(:hint, max: 2_000)
  end

  @doc """
  The rule in one language, falling back to what it was written in.

  A rule that disappears for a reader whose language nobody translated is worse
  than one they have to read in the original.
  """
  @spec text(t(), String.t() | nil) :: String.t()
  def text(rule, nil), do: rule.text

  def text(rule, locale) do
    case Map.get(rule.translations || %{}, to_string(locale)) do
      translated when is_binary(translated) and translated != "" -> translated
      _ -> rule.text
    end
  end
end

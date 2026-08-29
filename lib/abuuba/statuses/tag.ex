defmodule Abuuba.Statuses.Tag do
  @moduledoc """
  A hashtag.

  The name is stored casefolded, so `#Caturday` and `#caturday` are one tag and
  one timeline. The spelling first seen is kept separately for display, which
  is why `#ThisReadsBetter` still renders with its capitals.

  The three flags are moderation controls rather than user settings: `usable`
  stops new posts from being filed under it, `trendable` keeps it out of the
  trends list, and `listable` hides it from search and directories.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # A hashtag is letters, digits and underscores; the leading # is punctuation
  # around the tag, not part of it. Refusing an all-digit tag matches what
  # every client does when it linkifies text, so that a tag we store is a tag a
  # reader can actually click.
  # `\p{L}` rather than `[[:alpha:]]`: the POSIX classes stay ASCII-only even
  # with the `u` modifier, which would have refused #Grüße and #日本語.
  # The separators the rest of the network allows inside a hashtag: the
  # underscore, the middle dot, the katakana middle dot and a zero-width
  # non-joiner. The last three are ordinary in Japanese and in several Indic
  # scripts, and refusing them meant a post carrying one arrived with that
  # hashtag missing -- never listed under the tag, and the same tag on two
  # servers was two different things. A letter or an underscore is still
  # required, so a string of digits or of dots alone is not a hashtag.
  @name_separators "_\u00B7\u30FB\u200C"
  # Starts and ends with an ordinary character, may carry separators between,
  # and has to contain a letter or an underscore somewhere -- so `猫・犬` is a
  # hashtag, `猫・` is `猫` with punctuation after it, and `12345` is a number.
  @name_format ~r/\A(?=[\p{L}\p{N}#{@name_separators}]*[\p{L}_])[\p{L}\p{N}_](?:[\p{L}\p{N}#{@name_separators}]*[\p{L}\p{N}_])?\z/u
  @name_max 100

  schema "tags" do
    field :name, :string
    field :display_name, :string

    field :usable, :boolean, default: true
    # Nullable on purpose: null is "nobody has reviewed this yet", which is not
    # the same answer as "no". See `Abuuba.Trends`.
    field :trendable, :boolean
    field :listable, :boolean, default: true

    field :reviewed_at, :utc_datetime_usec
    field :requested_review_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Changeset for what a moderator decides about a tag.

  Reaches the three switches and nothing else. The name is not among them: a
  tag is identified by its name everywhere in the database and on every other
  server, and renaming one would silently move every post under it.
  """
  def moderation_changeset(tag, attrs) do
    cast(tag, attrs, [:usable, :trendable, :listable, :reviewed_at])
  end

  @doc """
  Changeset for a tag. The name is casefolded and the spelling given is kept
  as the display name.
  """
  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [
      :name,
      :display_name,
      :usable,
      :trendable,
      :listable,
      :reviewed_at,
      :requested_review_at
    ])
    |> validate_required([:name])
    # Normalise before validating, so that the leading # and any surrounding
    # space are gone by the time the format rule sees the name. Validating
    # first would reject every tag written the way people actually write them.
    |> put_display_name()
    |> update_change(:name, &normalise/1)
    |> validate_length(:name, max: @name_max)
    |> validate_format(:name, @name_format)
    |> unique_constraint(:name)
  end

  @doc """
  The casefolded form under which a tag is stored and looked up.
  """
  def normalise(name), do: name |> String.trim() |> String.trim_leading("#") |> String.downcase()

  # Remember how it was first written, unless the caller said otherwise.
  defp put_display_name(changeset) do
    case {get_change(changeset, :display_name), get_change(changeset, :name)} do
      {nil, written} when is_binary(written) ->
        put_change(changeset, :display_name, String.trim_leading(String.trim(written), "#"))

      _ ->
        changeset
    end
  end
end

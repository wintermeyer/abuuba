defmodule Abuuba.Instance.Announcement do
  @moduledoc """
  Something the people running a server want everybody to read.

  Dismissal is per account, because an announcement everybody dismissed at once
  would be one nobody could still be reading. Reactions are per account and per
  emoji for the same reason: a count is only meaningful if it is a count of
  people.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "announcements" do
    field :text, :string
    field :published, :boolean, default: false
    field :all_day, :boolean, default: false
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :published_at, :utc_datetime_usec
    # When it should publish itself. What turns "the server is down on Sunday"
    # into something written on Thursday and forgotten about, rather than
    # something somebody has to be awake to press.
    field :scheduled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(announcement, attrs) do
    announcement
    |> cast(attrs, [
      :text,
      :published,
      :all_day,
      :starts_at,
      :ends_at,
      :published_at,
      :scheduled_at
    ])
    |> validate_required([:text])
    |> validate_length(:text, min: 1, max: 20_000)
    |> put_published_at()
  end

  @doc """
  Whether an announcement should be shown now.

  Published, and inside its window where it has one. A window that has closed
  is what makes "the server is down on Sunday" stop being shown on Monday
  without anybody having to remember to take it down.
  """
  @spec current?(t(), DateTime.t()) :: boolean()
  def current?(announcement, now \\ DateTime.utc_now())

  def current?(%__MODULE__{published: false}, _now), do: false

  def current?(%__MODULE__{starts_at: starts_at, ends_at: ends_at}, now) do
    started? = is_nil(starts_at) or DateTime.compare(now, starts_at) != :lt
    ended? = not is_nil(ends_at) and DateTime.compare(now, ends_at) != :lt

    started? and not ended?
  end

  defp put_published_at(changeset) do
    case {get_field(changeset, :published), get_field(changeset, :published_at)} do
      {true, nil} -> put_change(changeset, :published_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end

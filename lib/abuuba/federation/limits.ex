defmodule Abuuba.Federation.Limits do
  @moduledoc """
  How much of an inbound document we are willing to keep.

  Every field here arrives from a stranger, and none of it has been through a
  validation any of us wrote. A display name can be a megabyte, a profile can
  carry ten thousand fields, and a poll can offer a hundred thousand options.
  None of those are attacks that break anything on their own; they are attacks
  on the database, on every timeline that renders them and on every client that
  has to draw them.

  The numbers match the reference implementation, which is the point. A name
  cut at a different length here would render differently in the same client
  against two servers, and an actor accepted there and refused here would look
  to its owner like their account had broken.

  ## Cut, do not refuse

  Everything here truncates. Rejecting an actor because its name is too long
  would hand any peer a way to make an account unfetchable, and refusing a post
  over a long media description would silently drop somebody's reply. What is
  kept is always the front of the value, because that is the part somebody
  wrote for a reader.
  """

  # An ActivityPub document is a few kilobytes. A megabyte is generous enough
  # that nothing legitimate reaches it.
  @max_document_bytes 1_048_576

  @name_characters 2_048
  # A content warning somebody else wrote. Ours are capped at 500 and theirs
  # are not capped at all on most implementations, so this is the same
  # generosity the display name gets: long enough that nothing real is cut,
  # short enough that a warning cannot be a wall.
  @spoiler_characters 2_048
  @summary_bytes 20 * 1024
  @field_count 50
  # 2047 rather than the 255 a local account gets. A remote server sets its own
  # limits and cutting to ours would corrupt what it sent.
  @field_characters 2_047
  @poll_options 500
  @media_description_characters 10_000

  @doc """
  How long a remote display name may be.
  """
  @spec name_characters() :: pos_integer()
  def name_characters, do: @name_characters

  @doc """
  How many bytes of a remote profile summary we keep.
  """
  @spec summary_bytes() :: pos_integer()
  def summary_bytes, do: @summary_bytes

  @doc """
  How many profile fields a remote account may have.
  """
  @spec field_count() :: pos_integer()
  def field_count, do: @field_count

  @doc """
  How long one side of a remote profile field may be.
  """
  @spec field_characters() :: pos_integer()
  def field_characters, do: @field_characters

  @doc """
  The largest document we will read at all.
  """
  @spec max_document_bytes() :: pos_integer()
  def max_document_bytes, do: @max_document_bytes

  @doc """
  A display name, cut to length.
  """
  @spec name(term()) :: String.t()
  def name(value), do: value |> text() |> String.slice(0, @name_characters)

  @doc """
  A profile summary, cut to length.

  Bounded in bytes rather than characters, because what it has to fit in is a
  column. Cut on a character boundary all the same: slicing bytes would leave
  an invalid UTF-8 tail, which Postgres refuses outright, turning an oversized
  bio into a failed insert rather than a shortened one.
  """
  @spec summary(term()) :: String.t()
  def summary(value) do
    value |> text() |> truncate_bytes(@summary_bytes)
  end

  @doc """
  A remote content warning, cut rather than refused.

  Refusing was what happened before: our own 500-character rule was applied to
  every post, so a peer whose warning ran longer had the whole post dropped --
  the reply nobody saw, which is what this module exists to prevent.
  """
  @spec spoiler(term()) :: String.t()
  def spoiler(value), do: value |> text() |> String.slice(0, @spoiler_characters)

  @doc "How long a remote content warning may be."
  @spec spoiler_characters() :: pos_integer()
  def spoiler_characters, do: @spoiler_characters

  @doc """
  Profile fields, bounded in number and in length.
  """
  @spec fields([map()] | term()) :: [%{name: String.t(), value: String.t()}]
  def fields(fields) when is_list(fields) do
    fields
    |> Enum.take(@field_count)
    |> Enum.map(fn field ->
      %{
        name: field |> get("name") |> text() |> String.slice(0, @field_characters),
        value: field |> get("value") |> text() |> String.slice(0, @field_characters)
      }
    end)
    |> Enum.reject(&(&1.name == "" or &1.value == ""))
  end

  def fields(_fields), do: []

  @doc """
  Poll options, bounded in number.
  """
  @spec poll_options([term()] | term()) :: [term()]
  def poll_options(options) when is_list(options), do: Enum.take(options, @poll_options)
  def poll_options(_options), do: []

  # Polls are the exception to the rule above, and the reason is worth keeping
  # next to the number. Cutting a poll's options changes what the people
  # voting are answering: the tallies are indexed by position, so a ten-option
  # poll cut to four leaves everybody choosing between options they were never
  # shown. So `Abuuba.Statuses.Poll.remote_changeset/2` takes this as a *bound*
  # and refuses past it, rather than calling `poll_options/1` to trim. A poll
  # with five hundred options is not a poll anybody wrote by hand.

  @doc "How many options a poll somebody else wrote may offer."
  @spec poll_options_max() :: pos_integer()
  def poll_options_max, do: @poll_options

  @doc """
  A media description, trimmed and cut to length.
  """
  @spec media_description(term()) :: String.t()
  def media_description(value) do
    value |> text() |> String.trim() |> String.slice(0, @media_description_characters)
  end

  @doc "How long a description somebody else wrote may be."
  @spec media_description_characters() :: pos_integer()
  def media_description_characters, do: @media_description_characters

  # Anything that is not a string is not text. A peer that sends an object
  # where a name belongs gets an empty name rather than a crash or a rendered
  # `%{}`.
  defp get(field, key) when is_map(field), do: Map.get(field, key)
  defp get(_field, _key), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  defp truncate_bytes(value, limit) when byte_size(value) <= limit, do: value

  defp truncate_bytes(value, limit) do
    # Back off to the last whole character that fits. At most three bytes of
    # backing off, since that is the longest character this can split.
    Enum.find_value(0..3, "", fn back ->
      candidate = binary_part(value, 0, limit - back)

      String.valid?(candidate) && candidate
    end)
  end
end

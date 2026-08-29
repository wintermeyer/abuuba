defmodule Abuuba.Instance.EmojiImages do
  @moduledoc """
  The picture behind a custom emoji this server offers.

  ## Held here rather than linked

  An emoji copied from another server is an address, and an address stops
  answering when that server goes away — leaving every post that used the
  shortcode with a hole in it. One uploaded here is a file on this server's own
  storage, which is the whole difference between offering an emoji and pointing
  at somebody else's.

  ## PNG and GIF, and nothing else

  A shortcode renders inline in somebody's sentence at the size of a letter.
  JPEG has no transparency and looks like a stamp on the text; SVG is a
  document that can carry script and would be served from this origin. Two
  formats cover what an emoji is for.

  ## Laid out the way the reference implementation lays it out

  `custom_emojis/images/<partitioned id>/original/<name>`, so a takeover that
  copies a Mastodon media tree finds every file where the row already says it
  is.
  """

  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Media.Storage

  @accepted ~w(image/png image/gif)

  # Small, because it is rendered at the size of a letter and sent to everybody
  # who reads a post using it. Mastodon's limit, so an emoji that travels here
  # from there fits.
  @max_bytes 256 * 1024

  @doc """
  Which types an emoji picture may be.
  """
  @spec accepted() :: [String.t()]
  def accepted, do: @accepted

  @doc """
  The largest an emoji picture may be.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Stores one, answering with the URL to serve it from.

  The id is supplied by the caller because the path contains it, and the row
  that will hold the URL does not exist yet.
  """
  @spec store(
          integer(),
          %{path: String.t(), filename: String.t(), content_type: String.t()},
          keyword()
        ) ::
          {:ok, String.t()} | {:error, :unsupported | :too_large | term()}
  def store(id, upload, opts \\ [])

  def store(id, %{path: path, filename: filename, content_type: content_type}, opts) do
    with :ok <- accept(content_type),
         :ok <- fits(path) do
      name = Storage.filename(filename)
      key = key(id, name)

      case Storage.put(key, path) do
        :ok ->
          # After the new file, never before: a failure between the two would
          # leave the row pointing at a picture that is not there, on every
          # post that ever used the shortcode.
          #
          # A shortcode already in use keeps its row and its id -- that is what
          # `put_local_emoji/1` is for -- and the key is derived from the
          # file's own hash, so a new picture is written beside the old one
          # rather than over it. Nothing else would ever reclaim it.
          discard_replaced(Keyword.get(opts, :replacing), key)

          {:ok, Storage.url(key)}

        error ->
          error
      end
    end
  end

  # Nothing to do when there was no picture, or when the new one landed on the
  # same key: there the file has already been written over the old one, and
  # deleting it would delete what was just stored.
  defp discard_replaced(previous_url, key) when is_binary(previous_url) do
    case key_from_url(previous_url) do
      nil -> :ok
      ^key -> :ok
      old -> Storage.delete(old)
    end
  end

  defp discard_replaced(_previous_url, _key), do: :ok

  @doc """
  Removes the file behind one, where this server is holding it.

  An emoji copied from elsewhere has nothing here to remove, and its address is
  not this server's to delete.
  """
  @spec discard(CustomEmoji.t()) :: :ok
  def discard(%CustomEmoji{domain: nil, image_url: url}) when is_binary(url) do
    case key_from_url(url) do
      nil -> :ok
      key -> Storage.delete(key)
    end
  end

  def discard(_emoji), do: :ok

  defp accept(content_type) when content_type in @accepted, do: :ok
  defp accept(_content_type), do: {:error, :unsupported}

  defp fits(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_bytes -> :ok
      {:ok, _stat} -> {:error, :too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp key(id, name), do: "custom_emojis/images/#{Storage.partition(id)}/original/#{name}"

  # The URL is what the row keeps, so removing the file means finding the key
  # inside it again. Only a path under this server's own media root is one.
  defp key_from_url(url) do
    case String.split(url, "/media/", parts: 2) do
      [_before, key] -> key
      _not_ours -> nil
    end
  end
end

defmodule Abuuba.Media.ProfileImages do
  @moduledoc """
  The two pictures an account is: its avatar and its header.

  Not media attachments. There is exactly one of each per account, it is
  replaced rather than added to, and it is read on every render of every post
  that account wrote — which is not something to reach a second table for. So
  they live in columns on `accounts`, which is also the shape a Mastodon
  database being taken over will hand us.

  ## Two sizes, and why both are stored

  An animated avatar has to stop moving somewhere: next to a hundred posts in a
  timeline, in a notification, anywhere a reader did not ask for motion. Every
  client expects a still copy at `avatar_static`, so one is written at upload
  time rather than composed on demand. For a picture that never moved, both
  point at the same file: writing a second identical copy would double the disk
  for nothing.

  ## Sized down on the way in

  An avatar is rendered at forty pixels and a header across the top of a
  profile. Storing the four-thousand-pixel photograph somebody dragged in means
  serving it at that size to every reader, so both are capped here, once, to
  what the largest rendering actually needs.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Media.Pipeline.Image
  alias Abuuba.Media.Storage

  # What the biggest rendering of each actually needs. Mastodon's numbers, so a
  # takeover of one of its databases does not have to re-cut every picture.
  @sizes %{avatar: {400, 400}, header: {1500, 500}}

  @kinds Map.keys(@sizes)

  # Anything a browser renders without help. A profile picture is decoration,
  # so an exotic format is refused rather than transcoded: the person can save
  # it as a PNG, and we do not carry a video decoder for an avatar.
  @accepted ~w(image/jpeg image/png image/gif image/webp)

  # Generous for a photograph off a phone and small enough that a slip of the
  # finger on a video file is refused before it is uploaded rather than after.
  @max_bytes 8 * 1024 * 1024

  @doc """
  The types a picture may be, for a form to state up front.
  """
  @spec accepted_types() :: [String.t()]
  def accepted_types, do: @accepted

  @doc """
  The largest a picture is kept at, by kind.
  """
  @spec size(atom()) :: {pos_integer(), pos_integer()}
  def size(kind) when kind in @kinds, do: Map.fetch!(@sizes, kind)

  @doc """
  The largest upload accepted, in bytes.

  Stated so a form can say it before somebody picks a file. A limit somebody
  learns about after a failed upload is a limit that wasted their time and
  this server's bandwidth.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The kinds of picture an account has.
  """
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Stores an uploaded picture and returns the columns to write.

  The caller writes them, because storing a file and updating a row are
  different failures: a picture on disk that no row points at is rubbish to be
  swept up, and a row pointing at a file that is not there is a broken image on
  every post its owner ever wrote.
  """
  @spec store(Account.t(), atom(), map()) :: {:ok, map()} | {:error, atom()}
  def store(%Account{} = account, kind, %{path: path, filename: filename} = upload)
      when kind in @kinds do
    content_type = content_type_of(upload, filename)

    with :ok <- accept(content_type),
         {:ok, source} <- with_extension(path, content_type),
         {:ok, prepared} <- prepare(source, kind, content_type) do
      write(account, kind, prepared, filename, content_type)
    end
  end

  def store(_account, _kind, _upload), do: {:error, :unsupported}

  # The image library reads and writes by file extension, and what arrives here
  # has none: a `Plug.Upload` path and a LiveView upload path are both a
  # temporary name with nothing on the end. So the file is linked to one that
  # carries the extension its content type implies — the type, not the name
  # somebody typed, because the name is a stranger's to write.
  #
  # Linked rather than copied, so a photograph off a phone is not written to
  # disk twice on the way in.
  defp with_extension(path, content_type) do
    extension = extension_for(content_type)

    if String.ends_with?(path, extension) do
      {:ok, path}
    else
      linked = path <> extension

      case File.ln_s(path, linked) do
        :ok -> {:ok, linked}
        {:error, :eexist} -> {:ok, linked}
        # A filesystem without symlinks is not a reason to refuse a picture.
        _error -> copy(path, linked)
      end
    end
  end

  defp copy(path, linked) do
    case File.cp(path, linked) do
      :ok -> {:ok, linked}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extension_for("image/jpeg"), do: ".jpg"
  defp extension_for("image/png"), do: ".png"
  defp extension_for("image/gif"), do: ".gif"
  defp extension_for("image/webp"), do: ".webp"
  defp extension_for(_type), do: ".bin"

  @doc """
  Forgets a picture, and takes its files with it.
  """
  @spec remove(Account.t(), atom()) :: map()
  def remove(%Account{} = account, kind) when kind in @kinds do
    for style <- [:original, :static] do
      case key_for(account, kind, style) do
        nil -> :ok
        key -> Storage.adapter().delete(key)
      end
    end

    %{
      :"#{kind}_file_name" => nil,
      :"#{kind}_content_type" => nil,
      :"#{kind}_file_size" => nil,
      :"#{kind}_updated_at" => nil,
      :"#{kind}_remote_url" => nil
    }
  end

  @doc """
  Where a client fetches an account's picture, or `""` where it has none.

  Empty rather than `nil`, because every client reads these as strings and a
  null is what makes one of them render the word "null" in an image tag.

  A remote account's picture is served from where it lives. That tells the
  other server which of our readers looked, which is what the media proxy in
  issue #175 is for; until then, the alternative is showing nothing at all.
  """
  @spec url(Account.t(), atom(), atom()) :: String.t()
  def url(account, kind, style \\ :original)

  def url(%Account{} = account, kind, style) when kind in @kinds do
    cond do
      key = key_for(account, kind, style) -> Storage.adapter().url(key)
      remote = remote_url(account, kind) -> remote
      true -> ""
    end
  end

  @doc """
  Records where a remote account's pictures live, from its actor document.

  Only the addresses. Copying every picture on the fediverse onto our own disk
  is a different decision with a different cost, and it belongs with the media
  proxy rather than here.
  """
  @spec remote_attrs(map()) :: map()
  def remote_attrs(document) when is_map(document) do
    %{
      avatar_remote_url: image_url(document["icon"]),
      header_remote_url: image_url(document["image"])
    }
  end

  def remote_attrs(_document), do: %{}

  @doc """
  The `icon` and `image` an actor document publishes, for an account here.
  """
  @spec actor_properties(Account.t()) :: map()
  def actor_properties(%Account{} = account) do
    %{}
    |> put_image("icon", account, :avatar)
    |> put_image("image", account, :header)
  end

  ## Internals

  defp put_image(document, key, account, kind) do
    case url(account, kind) do
      "" ->
        document

      url ->
        Map.put(document, key, %{
          "type" => "Image",
          "mediaType" => Map.get(account, :"#{kind}_content_type") || "image/jpeg",
          "url" => url
        })
    end
  end

  defp image_url(%{"url" => url}) when is_binary(url), do: url
  defp image_url(url) when is_binary(url), do: url
  defp image_url([first | _rest]), do: image_url(first)
  defp image_url(_value), do: nil

  defp remote_url(account, kind) do
    case Map.get(account, :"#{kind}_remote_url") do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp accept(type) when type in @accepted, do: :ok
  defp accept(_type), do: {:error, :unsupported}

  # The original capped to what the largest rendering needs, and a still copy
  # beside it. `nil` for the still copy means the picture never moved, so the
  # two are the same file.
  defp prepare(path, kind, content_type) do
    {width, height} = Map.fetch!(@sizes, kind)
    still_path = path <> ".static"

    case Image.fit(path, width, height, content_type, still_path) do
      {:ok, %{animated: true}} -> {:ok, %{path: path, still: still_path}}
      {:ok, _result} -> {:ok, %{path: path, still: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(account, kind, prepared, filename, content_type) do
    name = Storage.filename(filename)
    adapter = Storage.adapter()

    with :ok <- adapter.put(key(account, kind, "original", name), prepared.path, []),
         :ok <- put_still(adapter, account, kind, name, prepared) do
      # After the new one is written, never before: a failure between the two
      # would leave the row pointing at a picture that is not there, which is a
      # broken image on every post its owner ever wrote.
      #
      # The key carries the filename, so a differently named upload writes
      # beside the old file rather than over it, and nothing reclaims that --
      # the orphan sweep looks for attachment rows with no post, and a profile
      # picture has never been one. Every change of picture was a permanent
      # file.
      discard_replaced(account, kind, name)

      {:ok,
       %{
         :"#{kind}_file_name" => name,
         :"#{kind}_content_type" => content_type,
         :"#{kind}_file_size" => file_size(prepared.path),
         :"#{kind}_updated_at" => DateTime.utc_now(),
         # Uploading your own picture is what replaces one copied from
         # somewhere else, so the old address goes with it.
         :"#{kind}_remote_url" => nil
       }}
    end
  end

  # Nothing to remove when the name has not changed: the new file has already
  # been written over the old one at the same key.
  defp discard_replaced(account, kind, name) do
    if replaced?(account, kind, name), do: delete_both_styles(account, kind)

    :ok
  end

  defp replaced?(account, kind, name) do
    previous = Map.get(account, :"#{kind}_file_name")

    is_binary(previous) and previous != "" and previous != name
  end

  defp delete_both_styles(account, kind) do
    for style <- [:original, :static], key = key_for(account, kind, style) do
      Storage.adapter().delete(key)
    end

    :ok
  end

  defp put_still(_adapter, _account, _kind, _name, %{still: nil}), do: :ok

  defp put_still(adapter, account, kind, name, %{still: still}) do
    adapter.put(key(account, kind, "static", name), still, [])
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> nil
    end
  end

  # `accounts/avatars/<partitioned id>/<style>/<name>`, which is the shape the
  # reference implementation uses. A takeover of one of its databases can then
  # move the files across without rewriting every path.
  defp key(%Account{id: id}, kind, style, name) do
    "accounts/#{kind}s/#{Storage.partition(id)}/#{style}/#{name}"
  end

  defp key_for(%Account{} = account, kind, style) do
    case Map.get(account, :"#{kind}_file_name") do
      name when is_binary(name) and name != "" ->
        # A still copy is only written for a picture that moves. Where there is
        # none, the original is already still and is what `avatar_static`
        # points at.
        key(account, kind, style_dir(account, kind, style), name)

      _ ->
        nil
    end
  end

  defp style_dir(account, kind, :static) do
    if animated?(Map.get(account, :"#{kind}_content_type")), do: "static", else: "original"
  end

  defp style_dir(_account, _kind, _style), do: "original"

  defp animated?("image/gif"), do: true
  defp animated?("image/webp"), do: true
  defp animated?(_type), do: false

  defp content_type_of(%{content_type: type}, _filename) when is_binary(type), do: type
  defp content_type_of(_upload, filename), do: MIME.from_path(filename || "")
end

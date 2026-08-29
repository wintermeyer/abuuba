defmodule Abuuba.Media.Pipeline.Image do
  @moduledoc """
  What happens to a picture between the upload and the timeline.

  ## Capped by pixels, not by width

  A panorama and a poster are the same amount of work at the same pixel count
  and completely different shapes, so the cap is on the product. Anything over
  it is scaled down by the ratio that fits, which keeps the aspect and does not
  turn a wide photograph into a small square.

  ## Metadata goes, the colour profile stays

  A photograph carries where it was taken and on what. Neither belongs in a
  public timeline, and somebody posting a picture has not agreed to publish
  their address. The ICC profile is the exception: dropping it makes wide-gamut
  images render wrong rather than merely unlabelled.

  ## The formats a browser cannot show become one it can

  HEIC and AVIF arrive from phones and are not universally rendered. Converting
  on the way in is the only place it can be done once instead of by every
  reader.
  """

  alias Abuuba.Media.Blurhash
  alias Vix.Vips.Image, as: Vips
  alias Vix.Vips.Operation

  # 3840 x 2160. The cap is the product, so a panorama is judged by how much
  # work it is rather than how wide it is.
  @max_pixels 3840 * 2160

  # What a timeline shows before somebody opens the picture.
  @thumbnail_pixels 640 * 360

  # Small enough that the transform is instant, large enough that the blur has
  # something to describe.
  @blurhash_side 32

  # Formats a browser will not reliably render, and what they become.
  @converted ~w(image/heic image/heif image/avif)

  @doc """
  Processes an image in place, returning what the attachment should record.
  """
  @spec process(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def process(path, thumbnail_path, content_type) do
    with {:ok, image} <- Vips.new_from_file(path),
         {:ok, capped} <- cap(image),
         :ok <- write(capped, path, content_type),
         {:ok, thumbnail} <- resize_to(capped, @thumbnail_pixels),
         :ok <- write(thumbnail, thumbnail_path, thumbnail_type(content_type)) do
      {:ok,
       %{
         width: Vips.width(capped),
         height: Vips.height(capped),
         thumbnail_width: Vips.width(thumbnail),
         thumbnail_height: Vips.height(thumbnail),
         blurhash: blurhash(capped),
         content_type: served_type(content_type)
       }}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  Fits a picture inside a box, in place, and writes a still copy beside it.

  For an avatar and a header, where the target is a shape rather than a pixel
  budget: both are rendered into a fixed frame, so what matters is that neither
  side is larger than that frame needs.

  The still copy is written only for a picture that moves. Every client expects
  one at `avatar_static`, and for a picture that never moved a second identical
  file is disk spent for nothing, so `animated: false` tells the caller to
  point both at the same file.
  """
  @spec fit(String.t(), pos_integer(), pos_integer(), String.t(), String.t()) ::
          {:ok, %{animated: boolean()}} | {:error, term()}
  def fit(path, width, height, content_type, still_path) do
    with {:ok, image} <- Vips.new_from_file(path),
         {:ok, fitted} <- fit_within(image, width, height),
         :ok <- write(fitted, path, content_type) do
      write_still(fitted, path, content_type, still_path)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # `n_pages` past one is vips saying the file holds several frames, which is
  # the only reliable way to tell an animated GIF or WebP from a still one:
  # the content type says the container, not whether anything moves in it.
  defp write_still(image, path, content_type, still_path) do
    if animated?(path) do
      with :ok <- write(image, still_path, thumbnail_type(content_type)) do
        {:ok, %{animated: true}}
      end
    else
      {:ok, %{animated: false}}
    end
  end

  defp animated?(path) do
    case Vips.new_from_file(path, n: -1) do
      {:ok, image} -> Vips.header_value(image, "n-pages") |> pages() > 1
      _ -> false
    end
  rescue
    _error -> false
  end

  defp pages({:ok, n}) when is_integer(n), do: n
  defp pages(_value), do: 1

  # Both bounds honoured, so a wide header comes out inside the frame rather
  # than inside whichever dimension was smaller.
  defp fit_within(image, width, height) do
    if Vips.width(image) <= width and Vips.height(image) <= height do
      {:ok, image}
    else
      Operation.thumbnail_image(image, width, height: height, size: :VIPS_SIZE_DOWN)
    end
  end

  @doc """
  Whether a picture of this type is re-encoded on the way in.
  """
  @spec converted?(String.t()) :: boolean()
  def converted?(content_type), do: content_type in @converted

  @doc """
  What a file of this type is served as once it has been through here.
  """
  @spec served_type(String.t()) :: String.t()
  def served_type(content_type) do
    if converted?(content_type), do: "image/jpeg", else: content_type
  end

  @doc "The pixel cap, for the instance document to report honestly."
  @spec max_pixels() :: pos_integer()
  def max_pixels, do: @max_pixels

  ## Inside

  defp cap(image) do
    if Vips.width(image) * Vips.height(image) > @max_pixels do
      resize_to(image, @max_pixels)
    else
      {:ok, image}
    end
  end

  # Target dimensions are worked out and rounded down before the resize rather
  # than left to a scale factor: rounding two dimensions up independently is
  # how an image scaled "to" the cap comes out a few hundred pixels over it.
  defp resize_to(image, pixels) do
    width = Vips.width(image)
    height = Vips.height(image)
    scale = :math.sqrt(pixels / (width * height))

    if scale >= 1 do
      {:ok, image}
    else
      target_width = max(floor(width * scale), 1)
      target_height = max(floor(height * scale), 1)

      # Both bounds, so the result fits inside the box rather than inside
      # whichever dimension vips decided to honour.
      Operation.thumbnail_image(image, target_width,
        height: target_height,
        size: :VIPS_SIZE_DOWN
      )
    end
  end

  # An animated GIF keeps its frames, so it is written back as it came rather
  # than flattened into one still by a re-encode.
  defp write(image, path, content_type) do
    Vips.write_to_file(image, path <> suffix(content_type) <> options(content_type))
  end

  defp suffix("image/png"), do: ""
  defp suffix("image/gif"), do: ""
  defp suffix("image/webp"), do: ""
  defp suffix(_content_type), do: ""

  # `strip` takes the camera, the location and the timestamps out. The ICC
  # profile is kept on purpose: without it a wide-gamut picture renders wrong
  # rather than merely unlabelled.
  defp options(content_type) do
    case content_type do
      "image/jpeg" -> "[Q=85,strip=true,keep=icc]"
      "image/png" -> "[strip=true,keep=icc]"
      "image/webp" -> "[Q=85,strip=true,keep=icc]"
      _ -> "[strip=true,keep=icc]"
    end
  end

  defp thumbnail_type(content_type) do
    case served_type(content_type) do
      "image/gif" -> "image/png"
      type -> type
    end
  end

  defp blurhash(image) do
    with {:ok, small} <- thumbnail_for_hash(image),
         {:ok, rgb} <- to_rgb(small),
         {:ok, pixels} <- Vips.write_to_binary(rgb) do
      Blurhash.encode(pixels, Vips.width(rgb), Vips.height(rgb))
    else
      _ -> nil
    end
  end

  defp thumbnail_for_hash(image) do
    scale =
      :math.sqrt(@blurhash_side * @blurhash_side / (Vips.width(image) * Vips.height(image)))

    if scale >= 1, do: {:ok, image}, else: Operation.resize(image, scale)
  end

  # Three bands, no alpha: a blurhash has no opinion about transparency, and a
  # fourth band would be read as the next pixel's red.
  defp to_rgb(image) do
    case Vips.bands(image) do
      3 -> {:ok, image}
      4 -> Operation.flatten(image)
      _ -> Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
    end
  end
end

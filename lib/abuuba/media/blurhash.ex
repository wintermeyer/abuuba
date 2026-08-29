defmodule Abuuba.Media.Blurhash do
  @moduledoc """
  Reading the average colour out of a blurhash.

  A blurhash is a short string that stands in for a picture while the picture
  loads. Decoding the whole thing means reconstructing a small bitmap, and the
  page then has to paint it; the average colour is four characters of the same
  string and is most of what the placeholder is for, since a solid block of
  roughly the right colour is what keeps a timeline from flashing white and
  jumping as images arrive.

  This module both writes them, from a small bitmap the pipeline hands it, and
  reads them, including the ones that came from another server, which is why
  every reading path here treats the string as something a stranger wrote.
  """

  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"

  # Four by four. More components describe the picture better and cost more
  # characters in every timeline payload; four is what the reference
  # implementation settled on and what clients are tuned for.
  @components 4

  @doc """
  Encodes a small RGB bitmap as a blurhash.

  `pixels` is a flat binary of `width * height` RGB triples, which is what
  every image library will hand over and what avoids this module knowing about
  any of them. Downscale before calling: the transform is over every pixel, and
  a blurhash of a full-size photograph costs the same as one of a thumbnail and
  looks identical.
  """
  @spec encode(binary(), pos_integer(), pos_integer()) :: String.t()
  def encode(pixels, width, height)
      when is_binary(pixels) and byte_size(pixels) == width * height * 3 do
    linear = linear_pixels(pixels)

    factors =
      for y <- 0..(@components - 1), x <- 0..(@components - 1) do
        factor(linear, width, height, x, y)
      end

    [dc | ac] = factors

    maximum = maximum_of(ac)

    size_flag = @components - 1 + (@components - 1) * 9

    [
      base83(size_flag, 1),
      base83(quantised_maximum(maximum), 1),
      base83(encode_dc(dc), 4),
      Enum.map(ac, &base83(encode_ac(&1, maximum), 2))
    ]
    |> IO.iodata_to_binary()
  end

  def encode(_pixels, _width, _height), do: ""

  ## Writing

  defp linear_pixels(pixels) do
    for <<r, g, b <- pixels>>, do: {srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b)}
  end

  defp factor(linear, width, height, component_x, component_y) do
    normalisation = if component_x == 0 and component_y == 0, do: 1, else: 2

    {r, g, b} =
      linear
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {{r, g, b}, index}, {acc_r, acc_g, acc_b} ->
        x = rem(index, width)
        y = div(index, width)

        basis =
          :math.cos(:math.pi() * component_x * x / width) *
            :math.cos(:math.pi() * component_y * y / height)

        {acc_r + basis * r, acc_g + basis * g, acc_b + basis * b}
      end)

    scale = normalisation / (width * height)

    {r * scale, g * scale, b * scale}
  end

  defp maximum_of([]), do: 1.0

  defp maximum_of(ac) do
    ac
    |> Enum.flat_map(fn {r, g, b} -> [abs(r), abs(g), abs(b)] end)
    |> Enum.max()
  end

  defp quantised_maximum(maximum) do
    maximum |> Kernel.*(166) |> Kernel.-(0.5) |> floor() |> max(0) |> min(82)
  end

  defp encode_dc({r, g, b}) do
    Bitwise.bsl(linear_to_srgb(r), 16) + Bitwise.bsl(linear_to_srgb(g), 8) + linear_to_srgb(b)
  end

  defp encode_ac({r, g, b}, maximum) do
    real_maximum = (quantised_maximum(maximum) + 1) / 166

    quantise(r, real_maximum) * 19 * 19 + quantise(g, real_maximum) * 19 +
      quantise(b, real_maximum)
  end

  defp quantise(value, maximum) do
    (sign_pow(value / maximum, 0.5) * 9 + 9.5) |> floor() |> max(0) |> min(18)
  end

  defp sign_pow(value, exponent) do
    sign = if value < 0, do: -1, else: 1

    sign * :math.pow(abs(value), exponent)
  end

  defp base83(value, length) do
    for index <- 1..length, into: "" do
      digit = value |> div(trunc(:math.pow(83, length - index))) |> rem(83)

      <<Enum.at(@alphabet, digit)>>
    end
  end

  defp srgb_to_linear(byte) do
    value = byte / 255

    if value <= 0.04045 do
      value / 12.92
    else
      :math.pow((value + 0.055) / 1.055, 2.4)
    end
  end

  defp linear_to_srgb(value) do
    value = value |> max(0.0) |> min(1.0)

    if value <= 0.0031308 do
      trunc(value * 12.92 * 255 + 0.5)
    else
      trunc((1.055 * :math.pow(value, 1 / 2.4) - 0.055) * 255 + 0.5)
    end
  end

  @doc """
  The average colour as a CSS hex string, or `nil` if the string is not a
  blurhash.

  `nil` rather than a guess: a placeholder in the wrong colour is worse than no
  placeholder, because it is the thing a reader sees first.
  """
  @spec average_colour(String.t() | nil) :: String.t() | nil
  def average_colour(hash) when is_binary(hash) do
    with {:ok, chars} <- decodable(hash),
         :ok <- right_length(chars),
         {:ok, dc} <- decode83(Enum.slice(chars, 2, 4)) do
      colour(dc)
    else
      _ -> nil
    end
  end

  def average_colour(_hash), do: nil

  defp decodable(hash) do
    chars = String.to_charlist(hash)

    if chars != [] and Enum.all?(chars, &(&1 in @alphabet)), do: {:ok, chars}, else: :error
  end

  # The first character says how many components the hash carries, and that
  # fixes its length exactly. A string of the right characters and the wrong
  # length is not a blurhash however plausible it looks.
  defp right_length([flag | _rest] = chars) do
    with {:ok, size} <- decode83([flag]) do
      across = rem(size, 9) + 1
      down = div(size, 9) + 1

      if length(chars) == 4 + 2 * across * down, do: :ok, else: :error
    end
  end

  defp decode83(chars) do
    Enum.reduce_while(chars, {:ok, 0}, fn char, {:ok, acc} ->
      case Enum.find_index(@alphabet, &(&1 == char)) do
        nil -> {:halt, :error}
        index -> {:cont, {:ok, acc * 83 + index}}
      end
    end)
  end

  # The average is stored already in the sRGB a screen wants, so there is no
  # gamma to undo here.
  defp colour(dc) do
    red = Bitwise.bsr(dc, 16)
    green = dc |> Bitwise.bsr(8) |> Bitwise.band(255)
    blue = Bitwise.band(dc, 255)

    "#" <>
      Enum.map_join(
        [red, green, blue],
        &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())
      )
  end
end

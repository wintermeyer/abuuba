defmodule Abuuba.Accounts.Preferences do
  @moduledoc """
  What somebody has asked the interface to do differently.

  Four of these are accessibility settings and they are here from the start
  rather than added later, because retrofitting them means auditing every
  component that already shipped. A person who needs reduced motion needs it on
  the first page they see, not once somebody remembers.

  Each defaults to letting the browser decide. `reduce_motion` and
  `high_contrast` have media queries the operating system already sets, so the
  default is to follow those; the stored preference is an override for somebody
  whose system setting is wrong for them, which happens more often than the
  media queries' existence suggests.
  """

  @accessibility ~w(reduce_motion high_contrast system_font disable_autoplay)

  # Not accessibility settings, and not styling: things the composer asks
  # about. They live in the same store because they are the same kind of thing
  # to a person, and they are listed apart because only the ones above become
  # classes on the document.
  @composer ~w(warn_missing_alt)

  @keys @accessibility ++ @composer

  @doc """
  The preferences somebody has set, with defaults filled in.
  """
  @spec for_user(map() | nil) :: %{String.t() => boolean()}
  def for_user(nil), do: defaults()

  def for_user(%{settings: settings}) when is_map(settings) do
    stored = Map.get(settings, "accessibility", %{})

    Map.merge(defaults(), Map.take(stored, @keys))
  end

  def for_user(_user), do: defaults()

  @doc """
  Every preference, off.
  """
  @spec defaults() :: %{String.t() => boolean()}
  def defaults, do: Map.new(@keys, &{&1, false})

  @doc """
  The keys somebody may set.
  """
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  The class names a preference adds to the document.

  Applied on `<html>` rather than deeper, because a preference like reduced
  motion has to reach every element including the ones a component renders
  without knowing about it.
  """
  @spec body_class(map()) :: String.t()
  def body_class(preferences) do
    preferences
    |> Map.take(@accessibility)
    |> Enum.filter(fn {_key, value} -> value == true end)
    |> Enum.map_join(" ", fn {key, _value} -> "prefers-" <> String.replace(key, "_", "-") end)
  end

  @doc """
  Merges a change into what is stored, keeping anything else in there.
  """
  @spec merge(map() | nil, map()) :: map()
  def merge(settings, changes) do
    settings = settings || %{}

    accessibility =
      settings
      |> Map.get("accessibility", %{})
      |> Map.merge(Map.take(normalise(changes), @keys))

    Map.put(settings, "accessibility", accessibility)
  end

  defp normalise(changes) do
    Map.new(changes, fn {key, value} ->
      {to_string(key), value in [true, "true", "1", 1, "on"]}
    end)
  end
end

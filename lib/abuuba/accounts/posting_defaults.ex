defmodule Abuuba.Accounts.PostingDefaults do
  @moduledoc """
  What the compose box starts with.

  Stored on the user rather than the account, because these are preferences
  about the interface rather than facts other servers need. A default audience
  is the setting people most regret not having: somebody whose posts should all
  be followers-only has to remember, every single time, and remembering once is
  the whole point of a default.

  Kept beside the accessibility preferences in the same settings map, under a
  key of their own so neither can overwrite the other.
  """

  alias Abuuba.Statuses.Status

  @defaults %{
    "visibility" => "public",
    "quote_policy" => "public",
    "language" => "en",
    "sensitive" => false,
    # Whether the app a post was written in is shown under it. On by default,
    # which is what every client and every other server assumes; somebody who
    # would rather not say which app they use turns it off and it disappears
    # from their posts for everybody, themselves included on other people's
    # screens. They still see it on their own.
    "show_application" => true
  }

  @doc """
  The defaults somebody has set, with the built-in ones filled in.
  """
  @spec for_user(map() | nil) :: map()
  def for_user(nil), do: @defaults

  def for_user(%{settings: settings} = user) when is_map(settings) do
    stored = settings |> Map.get("posting", %{}) |> Map.take(Map.keys(@defaults))

    @defaults
    |> Map.merge(%{"language" => language_of(user)})
    |> Map.merge(stored)
    |> sanitise()
  end

  def for_user(_user), do: @defaults

  @doc """
  The built-in ones.
  """
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc """
  Merges a change into what is stored, keeping anything else in the map.
  """
  @spec merge(map() | nil, map()) :: map()
  def merge(settings, changes) do
    settings = settings || %{}

    posting =
      settings
      |> Map.get("posting", %{})
      |> Map.merge(changes |> normalise() |> Map.take(Map.keys(@defaults)))
      |> sanitise()

    Map.put(settings, "posting", posting)
  end

  # Somebody's account language is the obvious first guess at what they write
  # in, and it is one fewer thing to set.
  defp language_of(%{locale: locale}) when is_binary(locale) and locale != "", do: locale
  defp language_of(_user), do: @defaults["language"]

  # A value nobody defined falls back rather than being stored. These end up on
  # a status changeset, and a settings map is not the place to discover that
  # "everyone" is not a visibility.
  defp sanitise(posting) do
    posting
    |> Map.update("visibility", "public", &keep(&1, visibilities(), "public"))
    |> Map.update("quote_policy", "public", &keep(&1, quote_policies(), "public"))
    |> Map.update("sensitive", false, &(&1 == true or &1 == "true"))
    |> Map.update("show_application", true, &(&1 == true or &1 == "true"))
    |> Map.update("language", @defaults["language"], &keep_language/1)
  end

  defp keep(value, allowed, fallback), do: if(value in allowed, do: value, else: fallback)

  defp keep_language(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*\z/, value),
      do: value,
      else: @defaults["language"]
  end

  defp keep_language(_value), do: @defaults["language"]

  defp normalise(changes), do: Map.new(changes, fn {key, value} -> {to_string(key), value} end)

  @doc """
  The audiences somebody may pick as a default.

  Direct is missing on purpose: a default of "only the people I name" turns
  every post somebody forgets to change into a message to nobody.
  """
  @spec visibilities() :: [String.t()]
  def visibilities, do: ~w(public unlisted private)

  @doc """
  The quote policies somebody may pick as a default.
  """
  @spec quote_policies() :: [String.t()]
  def quote_policies do
    Enum.map(Status.quote_policies(), &to_string/1)
  end
end

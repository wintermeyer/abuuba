defmodule Abuuba.I18n do
  @moduledoc """
  Which language a given reader gets, and why.

  Resolution runs in one order and stops at the first answer:

  1. the signed-in user's saved preference, because somebody who has said what
     they want should not be argued with by their browser;
  2. a choice made in this session, so a logged-out reader can switch language
     and have it stick;
  3. the browser's `Accept-Language`, which is right often enough to be worth
     honouring and costs the reader nothing;
  4. English.

  A locale is only ever one of `known_locales/0`. Anything else, from a stale
  session, a hand-edited database row or a header, falls through to the
  default rather than reaching Gettext, which would otherwise answer in
  msgids.
  """

  @default_locale "en"

  # English is the source language and German ships complete beside it. Adding
  # one here is not enough on its own: see `mix abuuba.gettext.check`, which
  # refuses to let a listed locale lag behind.
  @known_locales ~w(en de)

  # In their own language. See `language_name/1`.
  @language_names %{"en" => "English", "de" => "Deutsch"}

  @doc """
  The locales this server can answer in.
  """
  @spec known_locales() :: [String.t()]
  def known_locales, do: @known_locales

  @doc """
  What a language is called, in its own language.

  Its own rather than the reader's: somebody looking for their language in a
  picker is looking for the word they would write it with, and "German" is not
  a word a German speaker scans for.
  """
  @spec language_name(String.t()) :: String.t()
  def language_name(locale), do: Map.get(@language_names, locale, locale)

  @doc """
  The locale used when nothing else is known.
  """
  @spec default_locale() :: String.t()
  def default_locale, do: @default_locale

  @doc """
  Whether a locale is one we have translations for.
  """
  @spec known?(term()) :: boolean()
  def known?(locale) when is_binary(locale), do: locale in @known_locales
  def known?(_locale), do: false

  @doc """
  Picks a locale from everything known about the reader.

  Every argument is optional and may be `nil` or nonsense; the point of this
  function is that its callers never have to check.
  """
  @spec resolve(keyword()) :: String.t()
  def resolve(sources \\ []) do
    from_preference(sources[:user_locale]) ||
      from_preference(sources[:session_locale]) ||
      from_accept_language(sources[:accept_language]) ||
      @default_locale
  end

  defp from_preference(locale), do: if(known?(locale), do: locale)

  @doc """
  The best match for an `Accept-Language` header, or `nil`.

  Quality values decide the order, and a tagged locale matches its base
  language, so a browser asking for `de-AT` is answered in German rather than
  being sent to English for want of an Austrian catalogue.
  """
  @spec from_accept_language(String.t() | nil) :: String.t() | nil
  def from_accept_language(nil), do: nil

  def from_accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_language_range/1)
    # A quality of 0 means "not this one", which is a rejection rather than a
    # weak preference, so it must not be able to win by being the only entry.
    |> Enum.reject(fn
      nil -> true
      {_tag, quality} -> quality == 0.0
    end)
    |> Enum.sort_by(fn {_tag, quality} -> quality end, :desc)
    |> Enum.find_value(fn {tag, _quality} -> match_locale(tag) end)
  end

  def from_accept_language(_header), do: nil

  defp parse_language_range(range) do
    case range |> String.trim() |> String.split(";") do
      [""] -> nil
      [tag] -> {tag, 1.0}
      [tag | params] -> {String.trim(tag), quality(params)}
    end
  end

  defp quality(params) do
    params
    |> Enum.find_value(fn param ->
      case param |> String.trim() |> String.split("=") do
        ["q", value] -> parse_quality(value)
        _ -> nil
      end
    end)
    |> Kernel.||(1.0)
  end

  defp parse_quality(value) do
    case Float.parse(String.trim(value)) do
      {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
      _ -> nil
    end
  end

  # `*` means "anything will do", which is not a preference for any particular
  # language, so it is left to fall through to the default.
  defp match_locale("*"), do: nil

  defp match_locale(tag) do
    base = tag |> String.split("-") |> List.first() |> String.downcase()

    Enum.find(@known_locales, &(&1 == base))
  end
end

defmodule Mix.Tasks.Abuuba.Gettext.Check do
  @shortdoc "Fails if a shipped locale has untranslated or fuzzy strings"

  @moduledoc """
  Checks that every locale in `Abuuba.I18n.known_locales/0` is complete.

      $ mix abuuba.gettext.check

  German is a shipped language, not a best effort, so a string that only exists
  in English is a bug and not a to-do. Adding one is easy to do by accident:
  `mix gettext.extract --merge` writes the new msgid into every catalogue with
  an empty msgstr, and nothing else complains. Without this check the German
  UI would degrade one string at a time, and only a German-speaking reader
  would ever find out.

  A fuzzy entry counts as untranslated. Fuzzy means Gettext guessed the
  translation from a similar string it already had, which is a starting point
  for a translator and not something to show a reader.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    problems =
      Abuuba.I18n.known_locales()
      |> List.delete(Abuuba.I18n.default_locale())
      |> Enum.flat_map(&check_locale/1)

    if problems == [] do
      Mix.shell().info("Every shipped locale is complete.")
    else
      Mix.raise("""
      #{length(problems)} string(s) are missing a translation:

      #{Enum.join(problems, "\n")}

      Run `mix gettext.extract --merge` and fill in the empty msgstrs. Remove
      the `#, fuzzy` marker once you have checked the guess.
      """)
    end
  end

  defp check_locale(locale) do
    "priv/gettext/#{locale}/LC_MESSAGES/*.po"
    |> Path.wildcard()
    |> Enum.flat_map(&check_file(&1, locale))
  end

  defp check_file(path, locale) do
    path
    |> File.read!()
    |> parse_entries()
    |> Enum.filter(&incomplete?/1)
    |> Enum.map(fn %{msgid: msgid} ->
      "  #{locale}: #{Path.basename(path)}: #{inspect(msgid)}"
    end)
  end

  # Deliberately a small parser rather than a dependency on Gettext's internals,
  # which are private and have moved between versions. It only has to find
  # msgid/msgstr pairs and fuzzy markers, and a header entry has an empty msgid,
  # which is how it is skipped.
  defp parse_entries(content) do
    content
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&(&1.msgid == ""))
  end

  defp parse_entry(block) do
    %{
      msgid: extract(block, "msgid"),
      msgstr: extract(block, "msgstr"),
      plurals: Regex.scan(~r/^msgstr\[\d+\]\s+"(.*)"/m, block) |> Enum.map(&Enum.at(&1, 1)),
      fuzzy: Regex.match?(~r/^#,.*\bfuzzy\b/m, block)
    }
  end

  # Gettext wraps a long string over several lines; the continuations are bare
  # quoted strings on their own lines and belong to whatever came before them.
  defp extract(block, keyword) do
    case Regex.run(~r/^#{keyword}\s+"(.*)"((?:\n"(?:.*)")*)/m, block) do
      nil ->
        ""

      [_, first, continuation] ->
        rest = Regex.scan(~r/^"(.*)"/m, continuation) |> Enum.map_join(&Enum.at(&1, 1))
        first <> rest
    end
  end

  defp incomplete?(%{fuzzy: true}), do: true
  defp incomplete?(%{plurals: [_ | _] = plurals}), do: Enum.any?(plurals, &(&1 == ""))
  defp incomplete?(%{msgstr: msgstr}), do: msgstr == ""
end

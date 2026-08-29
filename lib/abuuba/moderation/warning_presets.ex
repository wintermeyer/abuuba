defmodule Abuuba.Moderation.WarningPresets do
  @moduledoc """
  Ready-made warning texts a moderator picks instead of retyping.

  Kept for the server rather than for one moderator, which is the whole point:
  two people writing to two accounts about the same thing should say the same
  thing, and the account that gets a curt sentence because it was a Friday has
  been treated differently from the one that got the careful paragraph.

  A preset is named by its title, and saving one with a title that already
  exists replaces it. That makes the form an edit as well as a create without a
  second screen, and it stops a list filling with three slightly different
  "Spam" entries nobody can choose between.

  Stored in the instance settings rather than in a table of their own. There
  are a handful of them, they are read whenever a moderator opens an account,
  and settings are already cached — a table would be a migration and a query
  for something that is a short list of strings.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Settings

  @key "warning_presets"

  # Long enough for a paragraph of explanation, and the same ceiling a strike's
  # own text has, so a preset can never be something that cannot be sent.
  @max_text 5_000
  @max_title 100

  @doc """
  Every preset, in the order they were added.
  """
  @spec all() :: [map()]
  def all do
    case Settings.get(@key) do
      list when is_list(list) -> Enum.filter(list, &valid?/1)
      _absent -> []
    end
  end

  @doc """
  The text of one, by title, or `nil`.
  """
  @spec text(String.t() | nil) :: String.t() | nil
  def text(nil), do: nil

  def text(title) do
    case Enum.find(all(), &(&1["title"] == title)) do
      %{"text" => text} -> text
      _missing -> nil
    end
  end

  @doc """
  Adds one, or replaces the one with the same title.

  Refuses a preset with nothing in it: an empty warning is a message the
  account receives and cannot act on.
  """
  @spec put(Account.t(), String.t(), String.t()) :: :ok | {:error, :blank}
  def put(%Account{} = actor, title, text) do
    title = title |> to_string() |> String.trim() |> String.slice(0, @max_title)
    text = text |> to_string() |> String.trim() |> String.slice(0, @max_text)

    if title == "" or text == "" do
      {:error, :blank}
    else
      Settings.put(@key, replace_or_append(all(), %{"title" => title, "text" => text}))

      # Recorded like any other change to the server's settings. A text that
      # goes out over the moderators' names should not be editable by one of
      # them without a trace.
      AuditLog.record(actor, "warning_preset.save", :setting, 0, %{"title" => title})

      :ok
    end
  end

  @doc """
  Removes the one with this title. Removing one that is not there is not an
  error: two moderators pressing the same button is not a problem to report.
  """
  @spec delete(Account.t(), String.t()) :: :ok
  def delete(%Account{} = actor, title) do
    Settings.put(@key, Enum.reject(all(), &(&1["title"] == title)))

    AuditLog.record(actor, "warning_preset.delete", :setting, 0, %{"title" => title})

    :ok
  end

  # In place where it already exists, so editing one does not move it to the
  # bottom of a list somebody has learned the order of.
  defp replace_or_append(presets, preset) do
    if Enum.any?(presets, &same_title?(&1, preset)) do
      Enum.map(presets, &replace_if_same(&1, preset))
    else
      presets ++ [preset]
    end
  end

  defp replace_if_same(existing, preset) do
    if same_title?(existing, preset), do: preset, else: existing
  end

  defp same_title?(one, other), do: one["title"] == other["title"]

  defp valid?(%{"title" => title, "text" => text}) when is_binary(title) and is_binary(text),
    do: true

  defp valid?(_other), do: false
end

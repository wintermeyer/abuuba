defmodule Abuuba.Moderation.DomainLists do
  @moduledoc """
  Domain blocks and allows as a file.

  ## Why a file at all

  A server that has decided about four hundred domains has made four hundred
  decisions, and the way those get shared is a list somebody publishes. Typing
  them in one at a time is not a thing anybody does twice, and it is the reason
  a new server's block list is usually empty for months.

  ## Importing adds, and never removes

  A file is somebody else's opinion arriving in one go. Applying it as a
  replacement would let one paste undo every decision this server had already
  made, silently, and the undo is not recoverable from the file. So an import
  is additive: domains already decided about are left exactly as they are, and
  the answer says how many were added and how many were already known.

  ## The format is Mastodon's

  `#domain,#severity,#public_comment` for blocks and `#domain` for allows,
  because the lists people publish are written by Mastodon's exporter and the
  point of reading a file is reading the files that exist.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Moderation.DomainBlock
  alias Abuuba.Moderation.Domains

  @doc """
  Every allow, as CSV.
  """
  @spec export_allows() :: String.t()
  def export_allows do
    encode(["#domain"], Enum.map(Domains.allows(), &[&1.domain]))
  end

  @doc """
  Reads an allow list in.
  """
  @spec import_allows(Account.t(), String.t()) :: {non_neg_integer(), non_neg_integer()}
  def import_allows(%Account{} = moderator, csv) do
    known = MapSet.new(Domains.allows(), & &1.domain)

    csv
    |> rows()
    |> Enum.reduce({0, 0}, fn row, {added, skipped} ->
      domain = row |> Enum.at(0) |> normalise()

      cond do
        domain == "" -> {added, skipped}
        MapSet.member?(known, domain) -> {added, skipped + 1}
        match?({:ok, _allow}, Domains.allow(moderator, domain)) -> {added + 1, skipped}
        true -> {added, skipped + 1}
      end
    end)
  end

  ## Plumbing

  # A header row's first field starts with `#`, which is how Mastodon writes
  # them and how this writes them back. Checked after the quotes come off
  # rather than on the raw line: our own exporter quotes every field, so a
  # naive check on the line would read `"#domain"` as data and re-import the
  # header as a domain.
  defp rows(csv) do
    csv
    |> to_string()
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&fields/1)
    |> Enum.reject(&header?/1)
  end

  defp header?([first | _rest]), do: String.starts_with?(first, "#")
  defp header?(_row), do: true

  defp fields(line) do
    line
    |> String.split(",")
    |> Enum.map(fn field ->
      field
      |> String.trim()
      |> String.trim("\"")
    end)
  end

  defp normalise(domain), do: DomainBlock.normalise(domain)

  # An unknown severity is a silence rather than a suspension. A file from
  # somebody else must not be able to delete accounts here because a column
  # said a word this server does not know.

  defp encode(header, rows) do
    [header | rows]
    |> Enum.map_join("\r\n", fn row ->
      Enum.map_join(row, ",", &("\"" <> String.replace(to_string(&1), "\"", "\"\"") <> "\""))
    end)
    |> Kernel.<>("\r\n")
  end
end

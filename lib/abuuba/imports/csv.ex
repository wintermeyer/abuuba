defmodule Abuuba.Imports.CSV do
  @moduledoc """
  The lists a fediverse server exports: follows, blocks, mutes, lists,
  bookmarks, domain blocks, filters.

  These are the files somebody downloads from their old server on the way out.
  They are small, plain, and the format is a de facto standard rather than a
  written one, so this reads them the way they actually arrive rather than the
  way a specification would like them to.

  ## Working out what a file is

  Nobody renames these. `following_accounts.csv` is what the browser saved and
  the header row inside it says the same thing twice over, so both are used:
  the headers first, because they are what the file contains, then the name,
  because a file with no headers still has one.

  A file that is neither is refused rather than guessed at. Reading a block
  list as a follow list would have somebody follow the accounts they were
  hiding from.

  ## Headers are matched loosely

  `Account address`, `account address`, `#account address` — servers have
  written all three, and a header nobody recognises would turn a follow list
  into an empty import. Matching is case-insensitive and ignores the `#` some
  exporters prefix.

  ## A file with no header row is still a file

  The oldest exports are one address per line and nothing else. When the first
  row does not look like headers it is read as data, because a file whose first
  follow is silently dropped is worse than one that is refused.
  """

  # What Mastodon writes, which is what every other server copied.
  @headers %{
    "account address" => :acct,
    "show boosts" => :show_reblogs,
    "notify on new posts" => :notify,
    "languages" => :languages,
    "hide notifications" => :hide_notifications,
    "domain" => :domain,
    "uri" => :uri,
    "list name" => :list_name,
    "title" => :title,
    "context" => :context,
    "keyword" => :keyword,
    "action" => :action
  }

  # Twenty thousand rows. Past that somebody is not importing a follow list,
  # and a file that takes an hour to read is one nobody can tell has stalled.
  @max_rows 20_000

  @kinds ~w(following blocking muting domain_blocking bookmarks lists filters)a

  @doc """
  The kinds of list that can be read.
  """
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  The most rows one file may have.
  """
  @spec max_rows() :: pos_integer()
  def max_rows, do: @max_rows

  @doc """
  Reads a file into rows, working out what kind of list it is.

  `{:ok, kind, rows}`, or an error naming what is wrong with it.
  """
  @spec read(String.t(), String.t()) ::
          {:ok, atom(), [map()]} | {:error, :unknown_list | :empty_file | :too_many_rows}
  def read(contents, filename) do
    lines = split(contents)

    with {:ok, header, body} <- headers(lines),
         {:ok, kind} <- kind(header, filename),
         :ok <- within_limit(body) do
      {:ok, kind, rows(header, body, kind)}
    end
  end

  @doc """
  What kind of list a file is, from its headers and then its name.
  """
  @spec kind([atom()] | nil, String.t()) :: {:ok, atom()} | {:error, :unknown_list}
  def kind(header, filename) do
    case from_headers(header) || from_filename(filename) do
      nil -> {:error, :unknown_list}
      kind -> {:ok, kind}
    end
  end

  ## Working it out

  # The headers say what the file holds, and one distinctive column is enough:
  # `Hide notifications` appears in a mute list and nowhere else. In order,
  # because a filter file has a keyword and a context and a follow list has
  # neither.
  @by_column [
    {:hide_notifications, :muting},
    {:show_reblogs, :following},
    {:notify, :following},
    {:list_name, :lists},
    {:keyword, :filters},
    {:context, :filters},
    {:domain, :domain_blocking},
    {:uri, :bookmarks}
  ]

  defp from_headers(nil), do: nil

  defp from_headers(header) do
    Enum.find_value(@by_column, fn {column, kind} -> column in header and kind end)
  end

  # Nobody renames these files, and the ones with a single unlabelled column
  # have nothing else to go on. In order: `blocked_domains.csv` is a domain
  # list rather than a block list, and it contains both words.
  @by_name [
    {"mute", :muting},
    {"follow", :following},
    {"domain", :domain_blocking},
    {"block", :blocking},
    {"bookmark", :bookmarks},
    {"list", :lists},
    {"filter", :filters}
  ]

  defp from_filename(filename) do
    name = String.downcase(filename || "")

    Enum.find_value(@by_name, fn {word, kind} -> String.contains?(name, word) and kind end)
  end

  ## Reading

  defp split(contents) do
    contents
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp headers([]), do: {:error, :empty_file}

  defp headers([first | rest] = lines) do
    case header_row(first) do
      nil -> {:ok, nil, lines}
      header -> {:ok, header, rest}
    end
  end

  # A row is headers if its first cell is a name this code knows. Anything else
  # is data, which is what makes a headerless file readable rather than one row
  # short.
  defp header_row(line) do
    cells = cells(line)

    case Map.fetch(@headers, normalise(List.first(cells))) do
      {:ok, _known} -> Enum.map(cells, &Map.get(@headers, normalise(&1), :ignored))
      :error -> nil
    end
  end

  defp normalise(cell) do
    cell |> to_string() |> String.trim() |> String.trim_leading("#") |> String.downcase()
  end

  defp within_limit(body) when length(body) <= @max_rows, do: :ok
  defp within_limit(_too_many), do: {:error, :too_many_rows}

  defp rows(header, body, kind) do
    Enum.map(body, &row(header, cells(&1), kind))
  end

  # With headers, each cell is the column it sits under. Without them the first
  # cell is the only one that means anything, and which field it is depends on
  # what kind of list this turned out to be.
  defp row(nil, cells, kind) do
    %{lone_field(kind) => List.first(cells)}
  end

  defp row(header, cells, _kind) do
    header
    |> Enum.zip(cells)
    |> Enum.reject(fn {field, _value} -> field == :ignored end)
    |> Map.new()
  end

  defp lone_field(:domain_blocking), do: :domain
  defp lone_field(:bookmarks), do: :uri
  defp lone_field(_accounts), do: :acct

  # Enough of a CSV parser for files whose fields are addresses, booleans and
  # short names: quotes around a field that contains a comma, and doubled
  # quotes inside one. A list name is the only field anybody has ever put a
  # comma in.
  defp cells(line), do: line |> String.trim() |> parse_cells("", [], false)

  defp parse_cells("", current, cells, _quoted), do: Enum.reverse([current | cells])

  defp parse_cells(<<"\"\"", rest::binary>>, current, cells, true),
    do: parse_cells(rest, current <> "\"", cells, true)

  defp parse_cells(<<"\"", rest::binary>>, current, cells, quoted),
    do: parse_cells(rest, current, cells, not quoted)

  defp parse_cells(<<",", rest::binary>>, current, cells, false),
    do: parse_cells(rest, "", [current | cells], false)

  defp parse_cells(<<character::utf8, rest::binary>>, current, cells, quoted),
    do: parse_cells(rest, current <> <<character::utf8>>, cells, quoted)
end

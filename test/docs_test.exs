defmodule DocsTest do
  @moduledoc """
  The documentation is part of the product, so the parts of it that a machine
  can check are checked here.

  Not the prose — nothing here knows whether a page is any good. What it knows
  is that a link points at a file that exists, that every page is reachable
  from an index, and that the German mirror has not fallen behind. Those are
  the three ways documentation rots without anybody noticing, because none of
  them shows up when you read the page you just wrote.
  """

  use ExUnit.Case, async: true

  @english Path.wildcard("docs/user/*.md")
  @german Path.wildcard("docs/de/user/*.md")

  describe "every link in the documentation" do
    test "points at a file that exists" do
      broken =
        for page <- Path.wildcard("docs/**/*.md") ++ ["README.md"],
            target <- links(File.read!(page)),
            not remote?(target),
            path = target |> String.split("#") |> hd(),
            path != "",
            resolved = Path.expand(path, Path.dirname(page)),
            not File.exists?(resolved),
            do: "#{page} → #{target}"

      assert broken == []
    end

    test "and at a heading that exists, when it names one" do
      broken =
        for page <- Path.wildcard("docs/**/*.md"),
            target <- links(File.read!(page)),
            not remote?(target),
            [path, anchor] <- [String.split(target, "#", parts: 2)],
            file = if(path == "", do: page, else: Path.expand(path, Path.dirname(page))),
            File.exists?(file),
            anchor not in anchors(file),
            do: "#{page} → #{target}"

      assert broken == []
    end
  end

  describe "the user guide" do
    test "is completely mirrored in German" do
      # Page for page rather than name for name: the German pages have German
      # filenames, which is the point of translating them.
      assert length(@german) == length(@english),
             """
             #{length(@english)} English user pages and #{length(@german)} German ones.

             The German mirror is maintained page for page (see CLAUDE.md): a
             new English user page arrives with its translation, in the same
             commit, or the mirror is silently out of date and nobody finds out
             until a reader does.
             """
    end

    test "and every page in both is reachable from its index" do
      for {index, pages} <- [
            {"docs/user/README.md", @english},
            {"docs/de/user/README.md", @german}
          ] do
        listed = File.read!(index)

        for page <- pages, Path.basename(page) != "README.md" do
          assert listed =~ Path.basename(page),
                 "#{page} is not linked from #{index}, so nothing leads to it"
        end
      end
    end
  end

  defp links(markdown) do
    Regex.scan(~r/\[[^\]]*\]\(([^)]+)\)/, markdown, capture: :all_but_first)
    |> List.flatten()
  end

  defp remote?(target), do: String.starts_with?(target, ["http://", "https://", "mailto:"])

  # GitHub's own rule for turning a heading into an anchor: lowercase, drop
  # anything that is not a word character or a space, spaces become hyphens.
  defp anchors(file) do
    file
    |> File.stream!()
    |> Enum.filter(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      line
      |> String.trim_leading("#")
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
      |> String.replace(~r/\s+/u, "-")
    end)
  end
end

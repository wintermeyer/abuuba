defmodule Abuuba.Imports.CSVTest do
  use ExUnit.Case, async: true

  alias Abuuba.Imports.CSV

  describe "working out what a file is" do
    test "from the headers, which is what the file actually contains" do
      {:ok, kind, _rows} =
        CSV.read("Account address,Hide notifications\nbob@other.example,true\n", "renamed.csv")

      assert kind == :muting
    end

    test "and from the name when the headers do not say" do
      # A block list is one unlabelled column, so its name is all there is.
      {:ok, kind, _rows} = CSV.read("bob@other.example\n", "blocked_accounts.csv")

      assert kind == :blocking
    end

    test "refusing one that is neither" do
      # Reading a block list as a follow list would have somebody follow the
      # accounts they were hiding from.
      assert {:error, :unknown_list} = CSV.read("bob@other.example\n", "somefile.csv")
    end

    test "and one with nothing in it" do
      assert {:error, :empty_file} = CSV.read("\n\n", "follows.csv")
    end
  end

  describe "headers" do
    test "are matched however the exporter capitalised them" do
      {:ok, :following, [row]} =
        CSV.read("account address,show boosts\nbob@other.example,false\n", "x.csv")

      assert row.acct == "bob@other.example"
      assert row.show_reblogs == "false"
    end

    test "and with the hash some of them put in front" do
      {:ok, :domain_blocking, [row]} = CSV.read("#domain\nbad.example\n", "x.csv")

      assert row.domain == "bad.example"
    end

    test "columns nobody knows are left out rather than guessed at" do
      # A newer server adds a column and the file still has to be readable.
      {:ok, :following, [row]} =
        CSV.read("Account address,Show boosts,Something New\nbob@x.example,true,yes\n", "f.csv")

      assert row |> Map.keys() |> Enum.sort() == [:acct, :show_reblogs]
    end

    test "a file with only an address column is ambiguous, and its name decides" do
      # Follows, blocks and mutes can all be one address per row. Guessing
      # would have somebody follow the accounts they were hiding from.
      assert {:error, :unknown_list} = CSV.read("Account address\nbob@x.example\n", "x.csv")

      assert {:ok, :blocking, _rows} =
               CSV.read("Account address\nbob@x.example\n", "blocked_accounts.csv")
    end
  end

  describe "a file with no header row" do
    test "is read as data, not thrown away" do
      # The oldest exports are one address per line. Treating the first as a
      # header silently drops somebody's first follow.
      {:ok, :blocking, rows} =
        CSV.read("bob@other.example\ncarol@other.example\n", "blocked_accounts.csv")

      assert Enum.map(rows, & &1.acct) == ["bob@other.example", "carol@other.example"]
    end

    test "and the lone column means whatever the list is" do
      {:ok, :bookmarks, [row]} =
        CSV.read("https://other.example/users/bob/statuses/1\n", "bookmarks.csv")

      assert row.uri == "https://other.example/users/bob/statuses/1"
    end
  end

  describe "the rows themselves" do
    test "a quoted field can hold a comma, which list names do" do
      {:ok, :lists, [row]} =
        CSV.read("List name,Account address\n\"Friends, close\",bob@other.example\n", "x.csv")

      assert row.list_name == "Friends, close"
      assert row.acct == "bob@other.example"
    end

    test "and a doubled quote is one quote" do
      contents = ~s|List name,Account address\n"The ""good"" ones",bob@x.example\n|

      {:ok, :lists, [row]} = CSV.read(contents, "x.csv")

      assert row.list_name == ~s(The "good" ones)
    end

    test "carriage returns from a Windows export are not part of the address" do
      {:ok, :blocking, [row]} = CSV.read("bob@other.example\r\n", "blocks.csv")

      assert row.acct == "bob@other.example"
    end

    test "a file longer than the cap is refused rather than half read" do
      # Past twenty thousand rows somebody is not importing a follow list, and
      # a file that takes an hour is one nobody can tell has stalled.
      contents = "#domain\n" <> String.duplicate("bad.example\n", CSV.max_rows() + 1)

      assert {:error, :too_many_rows} = CSV.read(contents, "domain_blocks.csv")
    end
  end
end

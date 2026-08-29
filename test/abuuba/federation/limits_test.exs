defmodule Abuuba.Federation.LimitsTest do
  use ExUnit.Case, async: true

  alias Abuuba.Federation.Limits

  describe "a display name" do
    test "survives intact when it is a name" do
      assert Limits.name("Alice") == "Alice"
    end

    test "is cut rather than refused when it is a megabyte" do
      # Refusing the whole actor over an oversized name would mean a peer
      # could make an account unfollowable by giving it a long name.
      long = String.duplicate("a", 5_000)

      assert String.length(Limits.name(long)) == 2_048
    end

    test "counts characters, not bytes, so a name in Japanese is not halved" do
      long = String.duplicate("日", 3_000)

      assert String.length(Limits.name(long)) == 2_048
    end

    test "turns anything that is not a string into an empty one" do
      assert Limits.name(nil) == ""
      assert Limits.name(%{"content" => "hi"}) == ""
      assert Limits.name(42) == ""
    end
  end

  describe "a profile summary" do
    test "is bounded in bytes, because that is what the column holds" do
      long = String.duplicate("a", 30_000)

      assert byte_size(Limits.summary(long)) == 20 * 1024
    end

    test "is never cut through the middle of a character" do
      # Slicing bytes would leave an invalid UTF-8 tail, which Postgres
      # refuses outright, so an oversized bio would become a failed insert.
      long = String.duplicate("日", 20_000)
      cut = Limits.summary(long)

      assert String.valid?(cut)
      assert byte_size(cut) <= 20 * 1024
    end

    test "leaves an ordinary bio alone" do
      assert Limits.summary("Hello, I like trains.") == "Hello, I like trains."
    end
  end

  describe "profile fields" do
    test "keep the first fifty and drop the rest" do
      fields = for i <- 1..80, do: %{"name" => "n#{i}", "value" => "v#{i}"}

      kept = Limits.fields(fields)

      assert length(kept) == 50
      assert List.first(kept).name == "n1"
    end

    test "are cut at the length a remote field is allowed" do
      # 2047 rather than the 255 a local account gets: a remote server sets
      # its own limits, and cutting to ours would corrupt what it sent.
      field = %{"name" => String.duplicate("n", 3_000), "value" => String.duplicate("v", 3_000)}

      assert [%{name: name, value: value}] = Limits.fields([field])
      assert String.length(name) == 2_047
      assert String.length(value) == 2_047
    end

    test "drop a field with nothing on one side of it" do
      fields = [
        %{"name" => "", "value" => "v"},
        %{"name" => "n", "value" => ""},
        %{"name" => "n", "value" => "v"}
      ]

      assert Limits.fields(fields) == [%{name: "n", value: "v"}]
    end
  end

  describe "poll options" do
    test "stop at five hundred" do
      assert length(Limits.poll_options(for(i <- 1..900, do: "option #{i}"))) == 500
    end

    test "leave an ordinary poll alone" do
      assert Limits.poll_options(["yes", "no"]) == ["yes", "no"]
    end

    test "are nothing at all when there are none" do
      assert Limits.poll_options(nil) == []
      assert Limits.poll_options("not a list") == []
    end
  end

  describe "a media description" do
    test "is cut at ten thousand characters" do
      assert String.length(Limits.media_description(String.duplicate("a", 20_000))) == 10_000
    end

    test "loses the whitespace around it, which is never part of a description" do
      assert Limits.media_description("  a cat  ") == "a cat"
    end

    test "is nothing when there is none" do
      assert Limits.media_description(nil) == ""
    end
  end

  describe "the size of a document" do
    test "one megabyte is the most we read" do
      assert Limits.max_document_bytes() == 1_048_576
    end
  end
end

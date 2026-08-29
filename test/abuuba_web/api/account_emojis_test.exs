defmodule AbuubaWeb.API.AccountEmojisTest do
  @moduledoc """
  Custom emoji in a display name and a note.

  The account entity hardcoded an empty list, so a display name reading
  `alice :wave:` came back with the shortcode as literal text and every client
  rendered it that way.
  """

  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Instance
  alias AbuubaWeb.API.Entities

  setup do
    {:ok, emoji} =
      Instance.put_custom_emoji(%{
        shortcode: "wave",
        image_url: "https://abuuba.test/emoji/wave.png",
        static_url: "https://abuuba.test/emoji/wave.png"
      })

    Abuuba.Cache.invalidate(:custom_emojis)
    on_exit(fn -> Abuuba.Cache.invalidate(:custom_emojis) end)

    %{emoji: emoji}
  end

  describe "an account's own emoji" do
    test "come back for a shortcode in the display name" do
      account = account_fixture(%{username: "alice", display_name: "alice :wave:"})

      assert [%{"shortcode" => "wave"}] = Entities.account(account)["emojis"]
    end

    test "and for one in the note" do
      account = account_fixture(%{username: "alice", note: "say :wave: to me"})

      assert [%{"shortcode" => "wave"}] = Entities.account(account)["emojis"]
    end

    test "are listed once even when used twice" do
      account =
        account_fixture(%{username: "alice", display_name: ":wave:", note: ":wave: again"})

      assert length(Entities.account(account)["emojis"]) == 1
    end

    test "leave out a shortcode this server does not have" do
      account = account_fixture(%{username: "alice", display_name: "alice :nonexistent:"})

      assert Entities.account(account)["emojis"] == []
    end

    test "are empty for a profile that uses none" do
      account = account_fixture(%{username: "alice", display_name: "Alice"})

      assert Entities.account(account)["emojis"] == []
    end
  end

  describe "another server's account" do
    test "keeps its shortcodes rather than borrowing our pictures" do
      # Their `:wave:` is theirs. Lending it one of our images would put a
      # picture on somebody's profile that they never chose, which is the same
      # rule a remote post's shortcodes already follow.
      remote =
        remote_account_fixture(%{
          username: "bob",
          domain: "peer.example",
          display_name: "bob :wave:"
        })

      assert Entities.account(remote)["emojis"] == []
    end
  end

  describe "on a post" do
    test "the author's emoji ride along with every one of their posts" do
      author = account_fixture(%{username: "alice", display_name: "alice :wave:"})
      status = status_fixture(%{account_id: author.id, text: "no shortcode here"})

      rendered = Entities.status(status)

      # The post itself uses none, so this only works if the author's name was
      # looked at too.
      assert rendered["emojis"] == []
      assert [%{"shortcode" => "wave"}] = rendered["account"]["emojis"]
    end

    test "and a page of them stays one query for the lot" do
      author = account_fixture(%{username: "alice", display_name: "alice :wave:"})

      statuses =
        for index <- 1..10, do: status_fixture(%{account_id: author.id, text: "post #{index}"})

      rendered = Entities.statuses(statuses)

      assert length(rendered) == 10
      assert Enum.all?(rendered, &match?([%{"shortcode" => "wave"}], &1["account"]["emojis"]))
    end
  end
end

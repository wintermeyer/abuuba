defmodule Abuuba.RemoteEmojiTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Instance
  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Repo
  alias AbuubaWeb.API.Entities

  defp tag(name, url) do
    %{"type" => "Emoji", "name" => name, "icon" => %{"type" => "Image", "url" => url}}
  end

  describe "storing what another server sent" do
    test "keeps an emoji under its own domain" do
      assert ["blobcat"] =
               Instance.put_remote_emoji(
                 [tag(":blobcat:", "https://remote.example/blobcat.png")],
                 "remote.example"
               )

      assert %{"blobcat" => %CustomEmoji{domain: "remote.example"}} =
               Instance.remote_emoji("remote.example")
    end

    test "does not put it in our own list" do
      Instance.put_remote_emoji(
        [tag(":blobcat:", "https://remote.example/b.png")],
        "remote.example"
      )

      # Ours and theirs are two pictures with one name; the composer's picker
      # and the federation serializer must never see theirs.
      refute Enum.any?(Instance.custom_emojis(), &(&1.shortcode == "blobcat"))
    end

    test "refreshes the URL when the other end re-uploads it" do
      Instance.put_remote_emoji(
        [tag(":blobcat:", "https://remote.example/old.png")],
        "remote.example"
      )

      Instance.put_remote_emoji(
        [tag(":blobcat:", "https://remote.example/new.png")],
        "remote.example"
      )

      # An emoji re-uploaded there keeps its shortcode and gets a new address.
      # Storing the first one forever leaves a broken image in every post.
      assert %{"blobcat" => %{image_url: "https://remote.example/new.png"}} =
               Instance.remote_emoji("remote.example")

      assert Repo.aggregate(CustomEmoji, :count) == 1
    end

    test "keeps the same shortcode from two servers apart" do
      Instance.put_remote_emoji([tag(":blobcat:", "https://one.example/a.png")], "one.example")
      Instance.put_remote_emoji([tag(":blobcat:", "https://two.example/b.png")], "two.example")

      assert %{"blobcat" => %{image_url: "https://one.example/a.png"}} =
               Instance.remote_emoji("one.example")

      assert %{"blobcat" => %{image_url: "https://two.example/b.png"}} =
               Instance.remote_emoji("two.example")
    end

    test "ignores tags that are not emoji" do
      tags = [
        %{"type" => "Mention", "href" => "https://remote.example/users/bob"},
        %{"type" => "Hashtag", "name" => "#gardening"},
        %{"type" => "Emoji", "name" => ":nourl:"}
      ]

      assert Instance.put_remote_emoji(tags, "remote.example") == []
      assert Instance.remote_emoji("remote.example") == %{}
    end

    test "ignores a local domain, since ours are not learned this way" do
      assert Instance.put_remote_emoji([tag(":blobcat:", "https://x/y.png")], nil) == []
    end
  end

  describe "rendering" do
    setup do
      remote =
        account_fixture(%{
          username: "far",
          domain: "remote.example",
          display_name: "Far :blobcat:",
          uri: "https://remote.example/users/far",
          url: "https://remote.example/@far"
        })

      Instance.put_remote_emoji(
        [tag(":blobcat:", "https://remote.example/blobcat.png")],
        "remote.example"
      )

      %{remote: remote}
    end

    test "a remote post gets its own server's picture", %{remote: remote} do
      status = status_fixture(%{account_id: remote.id, text: "hello :blobcat:", local: false})

      [rendered] = Entities.statuses([status], nil)

      assert [%{"shortcode" => "blobcat", "url" => "https://remote.example/blobcat.png"}] =
               rendered["emojis"]
    end

    test "a remote profile gets its own server's picture", %{remote: remote} do
      rendered = Entities.account(remote, nil)

      assert [%{"shortcode" => "blobcat", "url" => "https://remote.example/blobcat.png"}] =
               rendered["emojis"]
    end

    test "a local post is never given a remote picture" do
      local = account_fixture(%{username: "alice"})
      status = status_fixture(%{account_id: local.id, text: "hello :blobcat:"})

      [rendered] = Entities.statuses([status], nil)

      # Lending our reader another server's image would put a picture in
      # somebody's post that they never chose.
      assert rendered["emojis"] == []
    end

    test "a remote post is never given one of ours", %{remote: remote} do
      {:ok, _ours} =
        Instance.put_custom_emoji(%{
          shortcode: "ourown",
          image_url: "https://ours.example/ourown.png"
        })

      status = status_fixture(%{account_id: remote.id, text: "hello :ourown:", local: false})

      [rendered] = Entities.statuses([status], nil)

      assert rendered["emojis"] == []
    end

    test "a shortcode nobody has renders as text", %{remote: remote} do
      status = status_fixture(%{account_id: remote.id, text: "hello :nosuch:", local: false})

      [rendered] = Entities.statuses([status], nil)

      assert rendered["emojis"] == []
    end
  end
end

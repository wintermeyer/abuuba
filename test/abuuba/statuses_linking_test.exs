defmodule Abuuba.StatusesLinkingTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Instance
  alias Abuuba.Notifications
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Tag
  alias AbuubaWeb.API.Entities

  setup do
    %{author: account_fixture()}
  end

  defp mentioned_ids(status) do
    Mention
    |> Repo.all()
    |> Enum.filter(&(&1.status_id == status.id))
    |> Enum.map(& &1.account_id)
  end

  defp tag_names(status) do
    status |> Repo.preload(:tags) |> Map.fetch!(:tags) |> Enum.map(& &1.name) |> Enum.sort()
  end

  describe "posting" do
    test "addresses everybody the text names", %{author: author} do
      alice = account_fixture(%{username: "alice"})

      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "hi @alice"})

      assert mentioned_ids(status) == [alice.id]
    end

    test "addresses somebody once however often they are named", %{author: author} do
      alice = account_fixture(%{username: "alice"})

      {:ok, status} =
        Statuses.create_status(%{account_id: author.id, text: "@alice @alice again"})

      assert mentioned_ids(status) == [alice.id]
    end

    test "quietly ignores a name nobody answers to", %{author: author} do
      # A typo in a handle is not a reason to refuse the post.
      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "hi @nobody"})

      assert mentioned_ids(status) == []
    end

    test "files the post under every tag it carries", %{author: author} do
      {:ok, status} =
        Statuses.create_status(%{account_id: author.id, text: "on #Elixir and #phoenix"})

      assert tag_names(status) == ["elixir", "phoenix"]
    end

    test "reuses a tag that already exists rather than making a second one", %{author: author} do
      {:ok, _} = Statuses.create_status(%{account_id: author.id, text: "#elixir"})
      {:ok, _} = Statuses.create_status(%{account_id: author.id, text: "#Elixir"})

      assert Repo.aggregate(from(t in Tag, where: t.name == "elixir"), :count) == 1
    end

    test "tells somebody they were named", %{author: author} do
      alice = account_fixture(%{username: "alice"})

      {:ok, _} = Statuses.create_status(%{account_id: author.id, text: "hi @alice"})

      assert [notification] = Notifications.list(alice)
      assert notification.type == "mention"
      assert notification.from_account_id == author.id
    end

    test "does not tell somebody they named themselves", %{author: author} do
      {:ok, _} =
        Statuses.create_status(%{account_id: author.id, text: "note to @#{author.username}"})

      assert Notifications.list(author) == []
    end

    test "a boost carries no text and addresses nobody", %{author: author} do
      alice = account_fixture(%{username: "alice"})
      {:ok, original} = Statuses.create_status(%{account_id: alice.id, text: "hi @alice"})

      {:ok, boost} = Statuses.boost(author, original)

      assert mentioned_ids(boost) == []
    end
  end

  describe "how long a post may be" do
    test "measures a post the way the composer's counter does", %{author: author} do
      # The counter and the changeset have to agree, or somebody is told there
      # is room left and the save fails anyway.
      text = String.duplicate("a", 480) <> " @bob@very-long-domain.example"

      assert {:ok, _} = Statuses.create_status(%{account_id: author.id, text: text})
    end

    test "refuses a local post over the limit", %{author: author} do
      long = String.duplicate("a", Abuuba.Instance.max_characters() + 1)

      assert {:error, changeset} = Statuses.create_status(%{account_id: author.id, text: long})
      assert %{text: [_]} = errors_on(changeset)
    end

    test "accepts a post from another server that is longer than ours may be" do
      # Their limit is theirs. Refusing the post here loses it, and every reply
      # to it then points at nothing.
      remote = remote_account_fixture()

      long = "<p>" <> String.duplicate("word ", 400) <> "</p>"

      assert {:ok, status} =
               Statuses.create_status(%{
                 account_id: remote.id,
                 local: false,
                 uri: "https://remote.example/statuses/long",
                 text: long
               })

      assert status.text == long
    end

    test "does not re-read another server's markup for handles and tags" do
      # Their mentions and tags arrive in the document as data. Reading them
      # back out of rendered HTML finds the anchors, not the people.
      account_fixture(%{username: "alice"})
      remote = remote_account_fixture()

      {:ok, status} =
        Statuses.create_status(%{
          account_id: remote.id,
          local: false,
          uri: "https://remote.example/statuses/markup",
          text: ~s(<a href="https://remote.example/tags/x">#x</a> hi @alice)
        })

      assert mentioned_ids(status) == []
      assert tag_names(status) == []
    end
  end

  describe "rendering" do
    test "does not lend our pictures to another server's shortcodes" do
      # Their :wave: is theirs. Showing our image for it puts a picture in
      # somebody's post that they never chose and we cannot vouch for.
      {:ok, _} =
        Instance.put_custom_emoji(%{shortcode: "wave", image_url: "https://x.test/w.png"})

      remote = remote_account_fixture()

      {:ok, status} =
        Statuses.create_status(%{
          account_id: remote.id,
          local: false,
          uri: "https://remote.example/statuses/emoji",
          text: "<p>hi :wave:</p>"
        })

      rendered = Entities.status(status)

      assert rendered["emojis"] == []
      refute rendered["content"] =~ "x.test"
    end
  end

  describe "editing" do
    test "adds somebody named in the new text", %{author: author} do
      alice = account_fixture(%{username: "alice"})
      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "hello"})

      {:ok, status} = Statuses.edit_status(status, %{"text" => "hello @alice"})

      assert mentioned_ids(status) == [alice.id]
    end

    test "quiets somebody the edit removed rather than deleting them", %{author: author} do
      # This used to delete the row, so that the post stopped being delivered
      # to somebody the author had decided not to talk to. Deleting it also
      # took away a post they had already read, because the mention is what
      # grants access to one addressed narrowly -- so a direct message could
      # vanish from the inbox of the person it was sent to. Silent answers the
      # original concern without that: no further notification, and no new
      # delivery, while what they already have stays readable.
      alice = account_fixture(%{username: "alice"})
      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "hi @alice"})

      {:ok, status} = Statuses.edit_status(status, %{"text" => "hi"})

      assert mentioned_ids(status) == [alice.id]
      assert [%Mention{silent: true}] = Repo.all(Mention)
    end

    test "and leaves a message they were sent readable", %{author: author} do
      alice = account_fixture(%{username: "alice"})

      {:ok, status} =
        Statuses.create_status(%{
          account_id: author.id,
          text: "only for @alice",
          visibility: :direct
        })

      assert Statuses.get_status(status.id, alice)

      {:ok, status} = Statuses.edit_status(status, %{"text" => "never mind"})

      assert Statuses.get_status(status.id, alice)
      # And the positive control on the other side: somebody who was never
      # named still cannot read it, so the assertion above is about the
      # mention rather than about the post being public.
      refute Statuses.get_status(status.id, account_fixture())
    end

    test "and does not tell them again if the handle comes back", %{author: author} do
      alice = account_fixture(%{username: "alice"})
      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "hi @alice"})

      {:ok, status} = Statuses.edit_status(status, %{"text" => "hi"})
      {:ok, _} = Statuses.edit_status(status, %{"text" => "hi @alice"})

      assert length(Notifications.list(alice)) == 1
      assert [%Mention{silent: false}] = Repo.all(Mention)
    end

    test "does not tell somebody twice about the same post", %{author: author} do
      alice = account_fixture(%{username: "alice"})
      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "hi @alice"})

      {:ok, _} = Statuses.edit_status(status, %{"text" => "hi @alice, fixed a typo"})

      assert length(Notifications.list(alice)) == 1
    end

    test "refiles the post when the tags change", %{author: author} do
      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "#elixir"})

      {:ok, status} = Statuses.edit_status(status, %{"text" => "#phoenix"})

      assert tag_names(status) == ["phoenix"]
    end
  end
end

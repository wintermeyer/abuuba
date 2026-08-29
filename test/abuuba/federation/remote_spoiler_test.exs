defmodule Abuuba.Federation.RemoteSpoilerTest do
  @moduledoc """
  A content warning somebody else wrote does not cost them the post.

  Ours are capped at 500 characters. That cap was applied to every post, so a
  peer whose warning ran longer had the whole thing refused -- the reply
  nobody saw, which is the failure `Abuuba.Federation.Limits` exists to prevent
  and says so in its own moduledoc. Most implementations do not cap warnings
  at all.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Federation.Limits
  alias Abuuba.Statuses.Status

  defp remote_changeset(spoiler) do
    author = remote_account_fixture(%{username: "alice", domain: "remote.example"})

    Status.changeset(%Status{}, %{
      account_id: author.id,
      local: false,
      uri: "https://remote.example/statuses/1",
      text: "hello",
      spoiler_text: spoiler,
      visibility: :public
    })
  end

  test "a warning longer than ours is kept, not refused" do
    changeset = remote_changeset(String.duplicate("a", 600))

    assert changeset.valid?, "a post was refused over the length of its own warning"
  end

  test "and one longer than anybody's is bounded rather than unbounded" do
    changeset = remote_changeset(String.duplicate("a", Limits.spoiler_characters() + 1))

    refute changeset.valid?
  end

  test "while ours are still held to five hundred" do
    # The control: the latitude is for warnings this server did not write.
    author = account_fixture()

    changeset =
      Status.changeset(%Status{}, %{
        account_id: author.id,
        local: true,
        text: "hello",
        spoiler_text: String.duplicate("a", 501),
        visibility: :public
      })

    refute changeset.valid?
  end

  test "the inbound path cuts before the changeset ever sees it" do
    # Which is why the bound above is a backstop rather than the answer: what
    # arrives is truncated, so nothing real is refused.
    assert String.length(Limits.spoiler(String.duplicate("a", 5_000))) ==
             Limits.spoiler_characters()
  end
end

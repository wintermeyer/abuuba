defmodule Abuuba.Importer.RebuildTest do
  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts.Account
  alias Abuuba.Importer.Rebuild
  alias Abuuba.Relationships.Follow
  alias Abuuba.Repo
  alias Abuuba.Timelines.Feed

  setup do
    now = DateTime.utc_now()

    Repo.insert_all(Account, [
      %{id: 1, username: "reader", inserted_at: now, updated_at: now},
      %{id: 2, username: "author", inserted_at: now, updated_at: now},
      %{id: 3, username: "stranger", inserted_at: now, updated_at: now}
    ])

    Repo.insert_all("users", [
      %{
        id: 30,
        account_id: 1,
        email: "reader@example.com",
        approved: true,
        settings: %{},
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(Follow, [
      %{id: 100, account_id: 1, target_account_id: 2, inserted_at: now, updated_at: now}
    ])

    Repo.insert_all("statuses", [
      status(10, 2, "public"),
      status(11, 1, "public"),
      status(12, 3, "public"),
      status(13, 2, "direct")
    ])

    :ok
  end

  defp status(id, account_id, visibility) do
    now = DateTime.utc_now()

    %{
      id: id,
      account_id: account_id,
      text: "",
      spoiler_text: "",
      visibility: visibility,
      quote_policy: "public",
      local: true,
      sensitive: false,
      ordered_media_attachment_ids: [],
      inserted_at: now,
      updated_at: now
    }
  end

  test "a home timeline is rebuilt from the follow graph" do
    # The source keeps feeds in Redis, which a takeover does not read. Without
    # this every account signs in to an empty timeline and concludes the
    # migration lost their posts.
    :ok = Rebuild.run([])

    assert Feed.status_ids("home", 1) == [11, 10]
  end

  test "and nothing from somebody the reader blocked" do
    # The rebuild goes through the same filtering the fan-out does. One with
    # its own idea of what belongs in a feed would put posts from blocked
    # accounts into somebody's timeline on the day they migrated.
    now = DateTime.utc_now()

    Repo.insert_all(Abuuba.Relationships.Block, [
      %{id: 200, account_id: 1, target_account_id: 2, inserted_at: now, updated_at: now}
    ])

    :ok = Rebuild.run([])

    refute 10 in Feed.status_ids("home", 1)
  end

  test "posts by people nobody follows stay out of it" do
    :ok = Rebuild.run([])

    refute 12 in Feed.status_ids("home", 1)
  end

  test "direct messages are not home timeline material" do
    # They reach somebody through their notifications and their conversations.
    :ok = Rebuild.run([])

    refute 13 in Feed.status_ids("home", 1)
  end

  test "running it again does not double the entries" do
    :ok = Rebuild.run([])
    :ok = Rebuild.run([])

    assert Feed.count("home", 1) == 2
  end

  test "verification notices an account that follows somebody and has nothing" do
    assert [%{name: "home timelines", checked: 1, failures: [%{id: 1}]}] = Rebuild.verify([])

    :ok = Rebuild.run([])

    assert [%{checked: 1, failures: []}] = Rebuild.verify([])
  end

  test "and does not ask for a timeline nobody could have" do
    # Somebody following nobody has an empty feed on purpose, and reporting it
    # as a failure would make every clean import look broken.
    now = DateTime.utc_now()

    Repo.insert_all(Account, [%{id: 4, username: "alone", inserted_at: now, updated_at: now}])

    Repo.insert_all("users", [
      %{
        id: 31,
        account_id: 4,
        email: "alone@example.com",
        approved: true,
        settings: %{},
        inserted_at: now,
        updated_at: now
      }
    ])

    :ok = Rebuild.run([])

    assert [%{checked: 2, failures: []}] = Rebuild.verify([])
  end
end

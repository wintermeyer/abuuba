defmodule Abuuba.RemoteVacuumTest do
  @moduledoc """
  What a retention on other servers' posts deletes, and what it refuses to.

  Every assertion here except the first is that a row **survived**, and a suite
  of those passes just as happily against a sweep that deletes nothing at all.
  So the first test is the positive control -- an ordinary old remote post
  really does go -- and each later one keeps that post alongside the one it is
  protecting, so a sweep that stopped working would fail them too.
  """
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Relationships
  alias Abuuba.Snowflake
  alias Abuuba.Statuses
  alias Abuuba.Statuses.RemoteVacuum
  alias Abuuba.Statuses.Status

  @days 30

  setup do
    %{
      remote: remote_account_fixture(%{username: "faraway", domain: "other.example"}),
      local: account_fixture()
    }
  end

  # Old enough to be swept. The cutoff is a snowflake comparison, so the id is
  # what makes a post old -- and an id is not castable through the ordinary
  # changeset, which is why this inserts the row rather than going through
  # `status_fixture/1`.
  defp old_remote(account, attrs \\ %{}) do
    at = DateTime.add(DateTime.utc_now(), -(@days + 1), :day)
    now = DateTime.utc_now()

    Repo.insert!(
      struct(
        %Status{
          id: Snowflake.id_at(at, System.unique_integer([:positive, :monotonic])),
          account_id: account.id,
          local: false,
          text: "an old post from elsewhere",
          visibility: :public,
          uri: "https://other.example/statuses/#{System.unique_integer([:positive])}",
          inserted_at: at,
          updated_at: now
        },
        attrs
      )
    )
  end

  defp swept?(status), do: is_nil(Repo.get(Status, status.id))

  describe "a retention of nothing" do
    test "deletes nothing at all", %{remote: remote} do
      status = old_remote(remote)

      assert RemoteVacuum.run(0) == {:ok, 0}
      assert RemoteVacuum.run(nil) == {:ok, 0}
      refute swept?(status)
    end
  end

  describe "a retention of thirty days" do
    test "deletes an old post from another server", %{remote: remote} do
      status = old_remote(remote)

      assert {:ok, 1} = RemoteVacuum.run(@days)
      assert swept?(status)
    end

    test "and leaves a recent one", %{remote: remote} do
      recent = status_fixture(%{account_id: remote.id, local: false})

      assert {:ok, 0} = RemoteVacuum.run(@days)
      refute swept?(recent)
    end

    test "and leaves our own however old", %{local: local} do
      mine = old_remote(local, %{local: true})

      assert {:ok, 0} = RemoteVacuum.run(@days)
      refute swept?(mine)
    end
  end

  describe "what somebody here kept" do
    setup %{remote: remote} do
      # The control, swept in every test below. Without it these are five
      # assertions that a sweep which does nothing would also satisfy.
      %{control: old_remote(remote), kept: old_remote(remote)}
    end

    test "a favourite", %{local: local, kept: kept, control: control} do
      {:ok, _} = Statuses.favourite(local, kept)

      assert {:ok, 1} = RemoteVacuum.run(@days)
      assert swept?(control)
      refute swept?(kept)
    end

    test "a bookmark", %{local: local, kept: kept, control: control} do
      {:ok, _} = Statuses.bookmark(local, kept)

      assert {:ok, 1} = RemoteVacuum.run(@days)
      assert swept?(control)
      refute swept?(kept)
    end

    test "a boost", %{local: local, kept: kept, control: control} do
      {:ok, _} = Statuses.boost(local, kept)

      assert {:ok, 1} = RemoteVacuum.run(@days)
      assert swept?(control)
      refute swept?(kept)
    end

    test "a reply", %{local: local, kept: kept, control: control} do
      status_fixture(%{account_id: local.id, text: "answering", in_reply_to_id: kept.id})

      assert {:ok, 1} = RemoteVacuum.run(@days)
      assert swept?(control)
      refute swept?(kept)
    end

    test "a mention of somebody here", %{local: local, kept: kept, control: control} do
      # Not about keeping the post: a mention is somebody's notification, and
      # deleting the post behind it leaves them a notification about nothing.
      {:ok, _} = Statuses.mention(kept, local)

      assert {:ok, 1} = RemoteVacuum.run(@days)
      assert swept?(control)
      refute swept?(kept)
    end

    test "but not a mention of somebody on another server", %{
      remote: remote,
      kept: kept,
      control: control
    } do
      other = remote_account_fixture(%{username: "elsewhere", domain: "third.example"})
      {:ok, _} = Statuses.mention(kept, other)
      _ = remote

      assert {:ok, 2} = RemoteVacuum.run(@days)
      assert swept?(control)
      assert swept?(kept)
    end

    test "and not a remote reply, which is as disposable as its parent", %{
      remote: remote,
      kept: kept,
      control: control
    } do
      old_remote(remote, %{text: "their answer", in_reply_to_id: kept.id})

      assert {:ok, 3} = RemoteVacuum.run(@days)
      assert swept?(control)
      assert swept?(kept)
    end
  end

  describe "a follow is not a reason to keep anything" do
    test "even for somebody we follow", %{local: local, remote: remote} do
      # Otherwise a retention would do nothing on the server that needs it: the
      # posts filling the disk are the ones our own people asked for.
      {:ok, _} = Relationships.follow(local, remote)
      status = old_remote(remote)

      assert {:ok, 1} = RemoteVacuum.run(@days)
      assert swept?(status)
    end
  end
end

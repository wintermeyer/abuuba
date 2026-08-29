defmodule Abuuba.ScheduledStatusesTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Statuses
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Statuses.ScheduledWorker

  setup do
    %{author: account_fixture()}
  end

  # A schedule the current `Statuses.schedule/3` would refuse, inserted the
  # way rows existed before it validated content.
  defp doomed_row(author, params) do
    Repo.insert!(%ScheduledStatus{
      account_id: author.id,
      scheduled_at: in_an_hour(),
      params: params,
      media_attachment_ids: []
    })
  end

  defp in_an_hour, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  describe "scheduling a post" do
    test "keeps the request rather than a half-built post", %{author: author} do
      # A draft stored among the published posts is a draft that the first
      # query which forgets to exclude it will publish.
      assert {:ok, scheduled} =
               Statuses.schedule(author, %{"text" => "later"}, in_an_hour())

      assert scheduled.params["text"] == "later"
      assert Statuses.public_timeline() == []
    end

    test "refuses a time too close to be a schedule", %{author: author} do
      # Scheduling is a queue rather than a timer: a post due in ten seconds
      # would be late often enough to look broken, and a client wanting to post
      # now can post now.
      soon = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:error, changeset} = Statuses.schedule(author, %{"text" => "soon"}, soon)
      assert %{scheduled_at: [_]} = errors_on(changeset)
    end

    test "refuses a time in the past", %{author: author} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:error, _} = Statuses.schedule(author, %{"text" => "then"}, past)
    end

    test "lists an account's own, soonest first", %{author: author} do
      {:ok, later} = Statuses.schedule(author, %{"text" => "b"}, DateTime.add(in_an_hour(), 60))
      {:ok, sooner} = Statuses.schedule(author, %{"text" => "a"}, in_an_hour())

      assert Enum.map(Statuses.scheduled(author), & &1.id) == [sooner.id, later.id]
    end

    test "lists nobody else's", %{author: author} do
      {:ok, _} = Statuses.schedule(author, %{"text" => "mine"}, in_an_hour())

      assert Statuses.scheduled(account_fixture()) == []
    end
  end

  describe "publishing what was kept" do
    test "carries the quote policy the author chose", %{author: author} do
      # Chosen when the post was written. Dropping it on the way out publishes
      # under a policy nobody picked.
      {:ok, scheduled} =
        Statuses.schedule(
          author,
          %{"text" => "later", "quote_policy" => "nobody"},
          in_an_hour()
        )

      assert {:ok, status} = Statuses.publish_scheduled(scheduled)
      assert status.quote_policy == :nobody
    end

    test "keeps a scheduled reply attached to its thread", %{author: author} do
      parent = status_fixture(%{account_id: account_fixture().id})

      {:ok, scheduled} =
        Statuses.schedule(
          author,
          %{
            "text" => "an answer",
            "in_reply_to_id" => parent.id,
            "in_reply_to_account_id" => parent.account_id
          },
          in_an_hour()
        )

      assert {:ok, status} = Statuses.publish_scheduled(scheduled)
      assert status.in_reply_to_id == parent.id
      assert status.in_reply_to_account_id == parent.account_id
    end

    test "asks the question a scheduled poll was written with", %{author: author} do
      # A poll dropped between writing and publishing is a post that goes out
      # saying "which of these?" with nothing to pick.
      {:ok, scheduled} =
        Statuses.schedule(
          author,
          %{
            "text" => "tabs or spaces?",
            "poll" => %{
              "options" => ["Tabs", "Spaces"],
              "multiple" => false,
              "expires_in" => 3600
            }
          },
          in_an_hour()
        )

      assert {:ok, status} = Statuses.publish_scheduled(scheduled)
      assert poll = Statuses.get_poll(status)
      assert poll.options == ["Tabs", "Spaces"]
    end

    test "runs a scheduled poll from when it goes out, not from when it was written",
         %{author: author} do
      {:ok, scheduled} =
        Statuses.schedule(
          author,
          %{"text" => "q", "poll" => %{"options" => ["a", "b"], "expires_in" => 3600}},
          in_an_hour()
        )

      {:ok, status} = Statuses.publish_scheduled(scheduled)

      assert DateTime.diff(Statuses.get_poll(status).expires_at, DateTime.utc_now(), :second) >
               3000
    end

    test "a poll nobody could answer does not take the post down with it", %{author: author} do
      # The post is the thing somebody wrote. Refusing to publish it because
      # its poll is malformed loses both.
      #
      # Scheduling refuses this shape now, so the row is written directly: it
      # stands for one scheduled before the validation existed, and the
      # publish path has to keep handling those.
      scheduled = doomed_row(author, %{"text" => "q", "poll" => %{"options" => ["only"]}})

      assert {:ok, status} = Statuses.publish_scheduled(scheduled)
      assert status.text == "q"
      refute Statuses.get_poll(status)
    end
  end

  describe "how many can be waiting" do
    test "refuses more than the ceiling", %{author: author} do
      # A queue nobody bounded is one somebody fills, and every entry is work
      # the publisher has to do at its appointed minute.
      for n <- 1..ScheduledStatus.limit() do
        {:ok, _} =
          Statuses.schedule(author, %{"text" => "#{n}"}, DateTime.add(in_an_hour(), n * 86_400))
      end

      assert {:error, changeset} = Statuses.schedule(author, %{"text" => "extra"}, in_an_hour())
      assert %{scheduled_at: [_]} = errors_on(changeset)
    end

    test "refuses more than the daily ceiling for one day", %{author: author} do
      day = in_an_hour()

      for n <- 1..ScheduledStatus.daily_limit() do
        {:ok, _} = Statuses.schedule(author, %{"text" => "#{n}"}, DateTime.add(day, n))
      end

      assert {:error, changeset} = Statuses.schedule(author, %{"text" => "extra"}, day)
      assert %{scheduled_at: [_]} = errors_on(changeset)
    end

    test "counts each day on its own", %{author: author} do
      day = in_an_hour()

      for n <- 1..ScheduledStatus.daily_limit() do
        {:ok, _} = Statuses.schedule(author, %{"text" => "#{n}"}, DateTime.add(day, n))
      end

      assert {:ok, _} =
               Statuses.schedule(author, %{"text" => "tomorrow"}, DateTime.add(day, 86_400))
    end

    test "counts nobody else's against yours", %{author: author} do
      day = in_an_hour()

      for n <- 1..ScheduledStatus.daily_limit() do
        {:ok, _} = Statuses.schedule(author, %{"text" => "#{n}"}, DateTime.add(day, n))
      end

      assert {:ok, _} = Statuses.schedule(account_fixture(), %{"text" => "mine"}, day)
    end
  end

  describe "changing a schedule" do
    setup %{author: author} do
      {:ok, scheduled} = Statuses.schedule(author, %{"text" => "later"}, in_an_hour())

      %{scheduled: scheduled}
    end

    test "moves it", %{scheduled: scheduled} do
      moved_to = DateTime.add(in_an_hour(), 7200, :second)

      assert {:ok, updated} = Statuses.reschedule(scheduled, moved_to)
      assert DateTime.compare(updated.scheduled_at, moved_to) == :eq
    end

    test "still refuses a time too close", %{scheduled: scheduled} do
      soon = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:error, _} = Statuses.reschedule(scheduled, soon)
    end

    test "cancelling forgets it", %{scheduled: scheduled, author: author} do
      assert {:ok, _} = Statuses.cancel_schedule(scheduled)
      assert Statuses.scheduled(author) == []
    end
  end

  describe "publishing what is due" do
    test "turns a due post into a real one", %{author: author} do
      {:ok, scheduled} = Statuses.schedule(author, %{"text" => "later"}, in_an_hour())

      assert {:ok, status} = Statuses.publish_scheduled(scheduled)
      assert status.text == "later"
      assert status.account_id == author.id
    end

    test "forgets the schedule once it has published", %{author: author} do
      # Left behind, it would publish again on the next sweep.
      {:ok, scheduled} = Statuses.schedule(author, %{"text" => "later"}, in_an_hour())
      {:ok, _} = Statuses.publish_scheduled(scheduled)

      assert Statuses.scheduled(author) == []
    end

    test "publishes only what is actually due", %{author: author} do
      {:ok, _soon} = Statuses.schedule(author, %{"text" => "a"}, in_an_hour())

      assert Statuses.due_schedules() == []
    end

    test "finds one whose time has come", %{author: author} do
      {:ok, scheduled} = Statuses.schedule(author, %{"text" => "a"}, in_an_hour())

      Repo.update_all(ScheduledStatus,
        set: [scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert [%{id: id}] = Statuses.due_schedules()
      assert id == scheduled.id
    end
  end

  describe "the worker that publishes them" do
    test "publishes what is due and leaves what is not", %{author: author} do
      {:ok, due} = Statuses.schedule(author, %{"text" => "now"}, in_an_hour())
      {:ok, _later} = Statuses.schedule(author, %{"text" => "later"}, in_an_hour())

      Repo.update_all(
        from(s in ScheduledStatus, where: s.id == ^due.id),
        set: [scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert :ok = ScheduledWorker.perform(%Oban.Job{args: %{}})

      assert [%{text: "now"}] = Statuses.public_timeline()
      assert [%{params: %{"text" => "later"}}] = Statuses.scheduled(author)
    end

    test "drops one that can no longer be published rather than retrying forever",
         %{author: author} do
      # The schedule is gone either way. Leaving it would mean trying again
      # every minute for the rest of the server's life.
      # Directly, standing for a row from before scheduling validated: the
      # worker is the backstop for those, and a backstop nobody tests is one
      # refactor from gone.
      broken = doomed_row(author, %{"text" => String.duplicate("a", 600)})

      Repo.update_all(
        from(s in ScheduledStatus, where: s.id == ^broken.id),
        set: [scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert :ok = ScheduledWorker.perform(%Oban.Job{args: %{}})

      assert Statuses.scheduled(author) == []
      assert Statuses.public_timeline() == []
    end
  end
end

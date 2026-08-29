defmodule Abuuba.Federation.RelaysTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.Delivery
  alias Abuuba.Federation.DeliveryWorker
  alias Abuuba.Federation.Handlers
  alias Abuuba.Federation.Relays
  alias Abuuba.Repo
  alias Abuuba.Statuses

  @inbox "https://relay.example/inbox"
  @relay_actor "https://relay.example/actor"
  @public "https://www.w3.org/ns/activitystreams#Public"

  defp queued do
    Repo.all(Oban.Job) |> Enum.map(& &1.args)
  end

  describe "subscribing" do
    test "a new relay is off until it is turned on" do
      {:ok, relay} = Relays.add(@inbox)

      assert relay.state == :idle
      assert queued() == []
      assert Relays.inboxes() == []
    end

    test "the same relay cannot be added twice" do
      {:ok, _relay} = Relays.add(@inbox)

      assert {:error, changeset} = Relays.add(@inbox)
      assert %{inbox_url: [_]} = errors_on(changeset)
    end

    test "turning one on sends it a Follow of the public collection" do
      # A relay is subscribed to by following the special public collection
      # rather than an actor. There is nobody there to follow.
      {:ok, relay} = Relays.add(@inbox)
      {:ok, relay} = Relays.enable(relay)

      assert relay.state == :pending
      assert is_binary(relay.follow_activity_id)

      assert [%{"inbox" => @inbox, "activity" => activity}] = queued()
      assert activity["type"] == "Follow"
      assert activity["object"] == @public
      assert activity["id"] == relay.follow_activity_id
    end

    test "a pending relay is not delivered to yet" do
      # Forwarding before the relay agreed would be sending posts to a server
      # that never said it wanted them.
      {:ok, relay} = Relays.add(@inbox)
      {:ok, _relay} = Relays.enable(relay)

      assert Relays.inboxes() == []
    end
  end

  describe "the relay answering" do
    setup do
      {:ok, relay} = @inbox |> Relays.add() |> elem(1) |> Relays.enable()

      %{relay: relay}
    end

    test "an Accept naming our Follow turns the subscription on", %{relay: relay} do
      assert {:ok, accepted} = Relays.accept(relay.follow_activity_id, @relay_actor)

      assert accepted.state == :accepted
      assert Relays.inboxes() == [@inbox]
    end

    test "a Reject leaves it off", %{relay: relay} do
      assert {:ok, rejected} = Relays.reject(relay.follow_activity_id, @relay_actor)

      assert rejected.state == :rejected
      assert Relays.inboxes() == []
    end

    test "an answer to a Follow we never sent is ignored" do
      assert :error = Relays.accept("https://relay.example/activities/made-up", @relay_actor)
      assert :error = Relays.reject(nil, @relay_actor)
    end

    test "an answer from anywhere but the relay itself is refused", %{relay: relay} do
      # A relay's Follow id is not a secret; the relay has it. Without the host
      # check any server that learned it could subscribe us to a relay, or
      # unsubscribe us from one.
      assert {:error, :wrong_host} =
               Relays.accept(relay.follow_activity_id, "https://elsewhere.example/actor")

      assert {:error, :wrong_host} = Relays.accept(relay.follow_activity_id, nil)

      assert Relays.inboxes() == []
    end

    test "an Accept delivered to the inbox turns the subscription on", %{relay: relay} do
      activity = %{
        "type" => "Accept",
        "actor" => @relay_actor,
        "object" => %{"id" => relay.follow_activity_id, "type" => "Follow"}
      }

      assert :ok = Handlers.handle(activity, actor_uri: @relay_actor)
      assert Relays.inboxes() == [@inbox]
    end

    test "a Reject delivered to the inbox leaves it off", %{relay: relay} do
      {:ok, _} = Relays.accept(relay.follow_activity_id, @relay_actor)

      activity = %{
        "type" => "Reject",
        "actor" => @relay_actor,
        "object" => relay.follow_activity_id
      }

      assert :ok = Handlers.handle(activity, actor_uri: @relay_actor)
      assert Relays.inboxes() == []
    end

    test "the same Accept arriving twice changes nothing", %{relay: relay} do
      {:ok, _} = Relays.accept(relay.follow_activity_id, @relay_actor)

      assert {:ok, again} = Relays.accept(relay.follow_activity_id, @relay_actor)
      assert again.state == :accepted
      assert Relays.inboxes() == [@inbox]
    end
  end

  describe "unsubscribing" do
    test "sends an Undo of the Follow and stops delivering" do
      {:ok, relay} = @inbox |> Relays.add() |> elem(1) |> Relays.enable()
      {:ok, relay} = Relays.accept(relay.follow_activity_id, @relay_actor)

      Repo.delete_all(Oban.Job)

      {:ok, relay} = Relays.disable(relay)

      assert relay.state == :idle
      assert Relays.inboxes() == []

      assert [%{"inbox" => @inbox, "activity" => undo}] = queued()
      assert undo["type"] == "Undo"
      assert undo["object"]["type"] == "Follow"
    end

    test "removing a relay that was never enabled sends nothing" do
      {:ok, relay} = Relays.add(@inbox)

      assert {:ok, _relay} = Relays.remove(relay)
      assert queued() == []
      assert Relays.list() == []
    end
  end

  describe "reach" do
    test "a public status goes to every accepted relay" do
      {:ok, relay} = @inbox |> Relays.add() |> elem(1) |> Relays.enable()
      {:ok, _relay} = Relays.accept(relay.follow_activity_id, @relay_actor)

      author = account_fixture()
      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "hi"})

      assert @inbox in Delivery.inboxes_for(author, status)
    end

    test "an unlisted or private status does not" do
      # A relay redistributes to strangers, which is the one thing a status
      # that is not public has asked us not to do.
      {:ok, relay} = @inbox |> Relays.add() |> elem(1) |> Relays.enable()
      {:ok, _relay} = Relays.accept(relay.follow_activity_id, @relay_actor)

      author = account_fixture()

      for visibility <- [:unlisted, :private, :direct] do
        {:ok, status} =
          Statuses.create_status(%{account_id: author.id, text: "hi", visibility: visibility})

        refute @inbox in Delivery.inboxes_for(author, status)
      end
    end

    test "a relay we have given up on is skipped like any other server" do
      {:ok, relay} = @inbox |> Relays.add() |> elem(1) |> Relays.enable()
      {:ok, _relay} = Relays.accept(relay.follow_activity_id, @relay_actor)

      for day <- 1..Availability.failure_days_before_unavailable() do
        Availability.record_failure("relay.example", Date.add(Date.utc_today(), -day))
      end

      author = account_fixture()
      {:ok, status} = Statuses.create_status(%{account_id: author.id, text: "hi"})

      refute @inbox in Delivery.inboxes_for(author, status)
    end
  end

  describe "delivering to a relay" do
    test "is signed as the instance actor, not as a person" do
      # There is no person involved in a relay subscription, and signing as one
      # would tell the relay which of our accounts triggered it.
      {:ok, relay} = Relays.add(@inbox)
      {:ok, _relay} = Relays.enable(relay)

      assert [%{"key_id" => key_id}] = queued()
      assert key_id =~ "/actor#main-key"
    end

    test "uses the push queue like every other delivery" do
      {:ok, relay} = Relays.add(@inbox)
      {:ok, _relay} = Relays.enable(relay)

      assert [job] = Repo.all(Oban.Job)
      assert job.queue == "push"
      assert job.worker == Atom.to_string(DeliveryWorker) |> String.replace_prefix("Elixir.", "")
    end
  end
end

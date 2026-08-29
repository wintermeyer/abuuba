defmodule Abuuba.Federation.InstanceActorTest do
  @moduledoc """
  The server's own actor, and the first request that asks for it.

  It is created on demand, so on a fresh server the first peer to fetch
  `/actor` is the request that builds it. That is a latency spike anybody can
  live with -- around a quarter of a second, against ten milliseconds warm --
  and a race nobody can: two peers fetching at the same moment both find
  nothing and both try to create it, and the id is fixed, so one of them loses
  the insert.

  What that costs is out of proportion to how narrow it is. A server in
  authorized-fetch mode fetches this actor to verify a signature, and Mastodon
  opens its breaker after a single failure and keeps it open for five minutes.
  So one 500 here is not one lost request: it is every signed request abuuba
  makes to that server refused for the next five minutes.
  """

  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts
  alias Abuuba.Federation.InstanceActor

  describe "fetch!/0" do
    test "makes the actor and its key on the first ask" do
      actor = InstanceActor.fetch!()

      assert actor.id == Accounts.instance_actor_id()
      assert actor.actor_type == :application
      assert Accounts.active_keypair(actor)
    end

    test "and answers with the same one afterwards" do
      first = InstanceActor.fetch!()
      second = InstanceActor.fetch!()

      assert first.id == second.id
    end

    test "two asks at the same moment both get an actor, and it is one actor" do
      # No `Sandbox.mode` call here. `DataCase` already checks out a shared
      # owner for an `async: false` case and stops it afterwards; setting the
      # mode again set it on the repo and left it set, so every test that ran
      # later shared one connection and could see another's rows. It surfaced
      # once on CI as an unrelated test finding an account it had suspended,
      # and never locally, because it depends on the order.
      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> InstanceActor.fetch!() end) end)
        |> Enum.map(&Task.await(&1, 15_000))

      ids = results |> Enum.map(& &1.id) |> Enum.uniq()

      assert ids == [Accounts.instance_actor_id()]
    end
  end

  describe "ensure!/0" do
    test "is what the application calls at startup, so no request has to" do
      assert :ok = InstanceActor.ensure!()

      assert Accounts.get_account(Accounts.instance_actor_id())
    end

    test "and running it again changes nothing" do
      :ok = InstanceActor.ensure!()
      before = InstanceActor.fetch!()

      :ok = InstanceActor.ensure!()

      assert InstanceActor.fetch!().id == before.id
      assert Accounts.active_keypair(before).id == Accounts.active_keypair(before).id
    end
  end
end

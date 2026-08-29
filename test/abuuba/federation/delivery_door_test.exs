defmodule Abuuba.Federation.DeliveryDoorTest do
  @moduledoc """
  Nothing goes to a server this one has decided not to talk to.

  `deliver_to/4` calls itself the one way anything reaches the push queue, and
  it is -- but the deciding was done by three of its callers rather than by the
  door, so anything that assembled its own inbox list walked past it. Report
  forwarding does exactly that: a local complaint about somebody on a suspended
  domain was signed by the instance actor and posted to the domain a moderator
  had just cut off. The same hole sent flag after flag to a server that had
  been dead for a week, sixteen retries each.

  Asked of the door itself rather than of the paths that use it, because the
  next path to be written will use the door too.
  """
  use Abuuba.DataCase, async: true

  import Ecto.Query
  import Abuuba.AccountsFixtures

  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.Delivery
  alias Abuuba.Moderation.Domains
  alias Abuuba.Repo

  defp queued_inboxes do
    Repo.all(
      from j in "oban_jobs",
        where: j.queue == "push",
        select: fragment("?->>'inbox'", j.args)
    )
  end

  defp activity, do: %{"type" => "Flag", "id" => "https://abuuba.test/flag/1"}

  setup do
    %{signer: account_fixture()}
  end

  test "an ordinary server is delivered to", %{signer: signer} do
    # The positive control, and this file needs it more than most: every other
    # assertion here is that nothing was queued, which is also what a broken
    # `deliver_to` would produce.
    Delivery.deliver_to(["https://ordinary.example/inbox"], activity(), signer)

    assert queued_inboxes() == ["https://ordinary.example/inbox"]
  end

  test "a suspended domain is not", %{signer: signer} do
    {:ok, _block} =
      Domains.block(account_fixture(), %{"domain" => "cut-off.example", "severity" => "suspend"})

    Delivery.deliver_to(["https://cut-off.example/inbox"], activity(), signer)

    assert queued_inboxes() == [],
           "a domain block promises that nothing goes to it, and something did"
  end

  test "and neither is a server we have given up on", %{signer: signer} do
    for day <- 1..Availability.failure_days_before_unavailable() do
      Availability.record_failure("dead.example", Date.add(Date.utc_today(), -day))
    end

    Delivery.deliver_to(["https://dead.example/inbox"], activity(), signer)

    assert queued_inboxes() == []
  end

  test "the reachable ones in a mixed list still go", %{signer: signer} do
    {:ok, _block} =
      Domains.block(account_fixture(), %{"domain" => "cut-off.example", "severity" => "suspend"})

    Delivery.deliver_to(
      ["https://cut-off.example/inbox", "https://ordinary.example/inbox"],
      activity(),
      signer
    )

    assert queued_inboxes() == ["https://ordinary.example/inbox"]
  end
end

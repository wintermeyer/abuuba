defmodule Abuuba.Federation.Availability do
  @moduledoc """
  Which servers have stopped answering, and when to give up on one.

  Counted in distinct days rather than in failures, and that distinction is the
  whole design. A server down for an hour produces thousands of failures and is
  not dead; a server that has failed on seven separate days is. Counting days
  is what tells a bad afternoon apart from an abandoned instance, and it is the
  difference between backing off sensibly and giving up on somebody's server
  because their disk filled up over lunch.

  Any successful contact with a domain clears the record, in either direction:
  a delivery that lands, a document we fetch, an inbound signed request. A
  server we are talking to is a server that is running, and continuing to treat
  it as dead because our own outbound attempts once failed would be believing
  our diagnosis over the evidence.

  ## Rows only for servers in trouble

  A healthy domain has no row here at all. Recording success is a single
  conditional `UPDATE` that matches nothing in the ordinary case, so the
  bookkeeping costs one statement that touches no rows rather than an upsert
  and a dead tuple on every request the fediverse sends us.
  """

  import Ecto.Query

  alias Abuuba.Moderation.DomainBlock
  alias Abuuba.Repo

  @failure_days_before_unavailable 7

  @doc """
  Records that every retry for this domain was exhausted today.
  """
  @spec record_failure(String.t(), Date.t()) :: :ok
  def record_failure(domain, today \\ Date.utc_today()) do
    domain = normalise(domain)
    row = fetch(domain)

    days = Enum.uniq([today | row.failure_days])

    unavailable_since =
      cond do
        row.unavailable_since -> row.unavailable_since
        length(days) >= @failure_days_before_unavailable -> DateTime.utc_now()
        true -> nil
      end

    now = DateTime.utc_now()

    Repo.insert_all(
      "instance_availability",
      [
        [
          domain: domain,
          failure_days: days,
          unavailable_since: unavailable_since,
          inserted_at: now,
          updated_at: now
        ]
      ],
      conflict_target: [:domain],
      on_conflict: [
        set: [failure_days: days, unavailable_since: unavailable_since, updated_at: now]
      ]
    )

    :ok
  end

  @doc """
  Records that a domain answered, or spoke to us.

  A no-op for a domain that was never in trouble, which is nearly all of them.
  """
  @spec record_success(String.t() | nil) :: :ok
  def record_success(nil), do: :ok

  def record_success(domain) do
    now = DateTime.utc_now()

    from(i in "instance_availability",
      where: i.domain == ^normalise(domain),
      # Never for a domain an admin stopped delivering to. That decision did
      # not mean "until they say something", and letting an inbound request
      # clear it would be the block undoing itself.
      where: is_nil(i.stopped_at),
      where: not is_nil(i.unavailable_since) or fragment("cardinality(?) > 0", i.failure_days)
    )
    |> Repo.update_all(
      set: [failure_days: [], unavailable_since: nil, last_success_at: now, updated_at: now]
    )

    :ok
  end

  @doc """
  Stops delivering to a domain until somebody says otherwise.

  Recorded apart from the failure count, because the two mean different things:
  one is a diagnosis this server made and can revise on new evidence, the other
  is a decision somebody took and only they can revise.
  """
  @spec stop(String.t()) :: :ok
  def stop(domain) do
    domain = normalise(domain)
    now = DateTime.utc_now()

    Repo.insert_all(
      "instance_availability",
      [
        [
          domain: domain,
          failure_days: [],
          unavailable_since: now,
          stopped_at: now,
          inserted_at: now,
          updated_at: now
        ]
      ],
      conflict_target: [:domain],
      on_conflict: [set: [unavailable_since: now, stopped_at: now, updated_at: now]]
    )

    :ok
  end

  @doc """
  Starts delivering to a domain again.

  Clears the failure count with it. Somebody who has decided the domain is
  worth talking to again should not have to wait out a week of evidence
  gathered before that decision.
  """
  @spec restart(String.t()) :: :ok
  def restart(domain) do
    now = DateTime.utc_now()

    from(i in "instance_availability", where: i.domain == ^normalise(domain))
    |> Repo.update_all(
      set: [failure_days: [], unavailable_since: nil, stopped_at: nil, updated_at: now]
    )

    :ok
  end

  @doc """
  Whether delivery to a domain was stopped by hand.
  """
  @spec stopped?(String.t() | nil) :: boolean()
  def stopped?(nil), do: false
  def stopped?(domain), do: not is_nil(fetch(normalise(domain)).stopped_at)

  @doc """
  Whether we have given up on a domain.
  """
  @spec unavailable?(String.t() | nil) :: boolean()
  def unavailable?(nil), do: false

  def unavailable?(domain) do
    not is_nil(fetch(normalise(domain)).unavailable_since)
  end

  @doc """
  The subset of these domains we have given up on.

  One query for the whole set. A popular post fans out to thousands of
  followers across a few hundred servers, and asking about each follower
  separately would be thousands of round trips to answer a few hundred
  questions.
  """
  @spec unavailable_among([String.t()]) :: MapSet.t()
  def unavailable_among([]), do: MapSet.new()

  def unavailable_among(domains) do
    domains = domains |> Enum.reject(&is_nil/1) |> Enum.map(&normalise/1) |> Enum.uniq()

    from(i in "instance_availability",
      where: i.domain in ^domains and not is_nil(i.unavailable_since),
      select: i.domain
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  How many distinct days a domain has failed on.
  """
  @spec failure_day_count(String.t()) :: non_neg_integer()
  def failure_day_count(domain), do: length(fetch(normalise(domain)).failure_days)

  @doc """
  How many distinct failure days mark a domain as gone.
  """
  def failure_days_before_unavailable, do: @failure_days_before_unavailable

  defp fetch(domain) do
    from(i in "instance_availability",
      where: i.domain == ^domain,
      select: %{
        failure_days: i.failure_days,
        unavailable_since: i.unavailable_since,
        stopped_at: i.stopped_at
      }
    )
    |> Repo.one()
    |> case do
      nil -> %{failure_days: [], unavailable_since: nil, stopped_at: nil}
      row -> row
    end
  end

  # `DomainBlock.normalise/1` rather than a fourth spelling: this one dropped
  # the trim and the trailing dot, and it keys `instance_availability`
  # alongside `Abuuba.Federation.Instances`, which did not.
  defp normalise(domain), do: DomainBlock.normalise(domain)
end

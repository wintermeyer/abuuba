defmodule Abuuba.Federation.Instances do
  @moduledoc """
  The servers this one has heard from, and how it is getting on with each.

  ## Why an admin needs this at all

  Domain blocks answer "should we talk to them". This answers the question that
  comes first and has nowhere else to be asked: *are* we talking to them, and if
  not, why not. A peer that has quietly stopped accepting deliveries looks
  exactly like a peer whose users have gone quiet, and an admin who cannot tell
  those apart finds out months later that half the network stopped hearing
  them.

  ## The list is built from the accounts

  There is no table of peers, and there does not need to be: a peer is a domain
  some account here has a row for, which is the same definition `/api/v1/peers`
  already uses. The availability row is joined in where there is one, and there
  is one only for a server that has been in trouble or that a moderator has
  written a note about.

  ## Software is a self-report

  What a peer says it is running, recorded because it tells an admin what they
  are looking at, and trusted for nothing else.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Availability
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status

  @doc """
  Every peer, with what is known about it.

  Ordered by how many accounts this server knows there, because that is the
  order an admin cares about: the servers most of their people are talking to.
  """
  @spec list(map()) :: [map()]
  def list(page \\ %{}) do
    limit = Map.get(page, :limit, 100)

    counts =
      Account
      |> where([a], not is_nil(a.domain))
      |> maybe_search(Map.get(page, :query))
      |> group_by([a], a.domain)
      |> select([a], %{domain: a.domain, accounts: count(a.id)})
      |> order_by([a], desc: count(a.id), asc: a.domain)
      |> limit(^limit)
      |> Repo.all()

    domains = Enum.map(counts, & &1.domain)

    posts = post_counts(domains)
    details = details_for(domains)
    blocks = blocks_for(domains)

    Enum.map(counts, fn row ->
      detail = Map.get(details, row.domain, %{})

      Map.merge(row, %{
        posts: Map.get(posts, row.domain, 0),
        software: Map.get(detail, :software),
        version: Map.get(detail, :version),
        note: Map.get(detail, :note),
        last_error: Map.get(detail, :last_error),
        last_error_at: Map.get(detail, :last_error_at),
        last_success_at: Map.get(detail, :last_success_at),
        stopped_at: Map.get(detail, :stopped_at),
        blocked: Map.get(blocks, row.domain),
        failure_days: length(Map.get(detail, :failure_days) || []),
        unavailable_since: Map.get(detail, :unavailable_since)
      })
    end)
  end

  @doc """
  One peer, or `nil` where nothing here has ever heard of it.
  """
  @spec get(String.t()) :: map() | nil
  def get(domain) do
    domain = normalise(domain)

    list(%{query: domain, limit: 1})
    |> Enum.find(&(&1.domain == domain))
  end

  @doc """
  Writes a moderator's note about one server.

  Creates the availability row if there is none, which is deliberate: a note is
  usually written about a server that is working perfectly well and therefore
  has no row yet.
  """
  @spec put_note(String.t(), String.t() | nil) :: :ok
  def put_note(domain, note) do
    upsert(domain, note: normalise_note(note))
  end

  @doc """
  Forgets the failures recorded against one server.

  For a peer that was down and is back, where waiting for the count to age out
  would leave it treated as unreliable for days after it stopped being so.
  """
  @spec clear_delivery_errors(String.t()) :: :ok
  def clear_delivery_errors(domain) do
    upsert(domain,
      failure_days: [],
      unavailable_since: nil,
      last_error: nil,
      last_error_at: nil
    )
  end

  @doc """
  Stops delivering to one server, and starts again.

  Thin wrappers over `Abuuba.Federation.Availability`, so that a screen about
  peers has one module to talk to rather than two.
  """
  @spec stop_delivery(String.t()) :: :ok
  def stop_delivery(domain), do: Availability.stop(domain)

  @doc """
  The other half of `stop_delivery/1`.
  """
  @spec restart_delivery(String.t()) :: :ok
  def restart_delivery(domain), do: Availability.restart(domain)

  @doc """
  Records what a peer says it is running.
  """
  @spec record_software(String.t(), String.t() | nil, String.t() | nil) :: :ok
  def record_software(domain, software, version) do
    upsert(domain, software: trim(software), version: trim(version))
  end

  @doc """
  Records why the last delivery to one server failed.
  """
  @spec record_error(String.t(), term()) :: :ok
  def record_error(domain, reason) do
    upsert(domain,
      last_error: reason |> inspect() |> String.slice(0, 200),
      last_error_at: DateTime.utc_now()
    )
  end

  ## Plumbing

  defp post_counts([]), do: %{}

  defp post_counts(domains) do
    Status
    |> join(:inner, [s], a in Account, on: a.id == s.account_id)
    |> where([_s, a], a.domain in ^domains)
    |> group_by([_s, a], a.domain)
    |> select([_s, a], {a.domain, count()})
    |> Repo.all()
    |> Map.new()
  end

  # The severity where there is a block, so the screen can say "blocked" rather
  # than offering to block a server that already is.
  defp blocks_for([]), do: %{}

  defp blocks_for(domains) do
    from(b in "domain_blocks",
      where: b.domain in ^domains,
      select: {b.domain, b.severity}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp details_for([]), do: %{}

  defp details_for(domains) do
    from(i in "instance_availability",
      where: i.domain in ^domains,
      select: %{
        domain: i.domain,
        software: i.software,
        version: i.version,
        note: i.note,
        last_error: i.last_error,
        last_error_at: i.last_error_at,
        last_success_at: i.last_success_at,
        stopped_at: i.stopped_at,
        failure_days: i.failure_days,
        unavailable_since: i.unavailable_since
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.domain, &1})
  end

  defp maybe_search(query, term) when term in [nil, ""], do: query

  defp maybe_search(query, term) do
    like = "%" <> String.replace(String.downcase(term), ~r/([%_\\])/, "\\\\\\1") <> "%"

    where(query, [a], like(a.domain, ^like))
  end

  # The row is created where there is none, because the things written here —
  # a note, a software name — are about servers that are working and therefore
  # have no failure row yet.
  defp upsert(domain, fields) do
    domain = normalise(domain)
    now = DateTime.utc_now()
    row = Keyword.merge([domain: domain, inserted_at: now, updated_at: now], fields)

    Repo.insert_all("instance_availability", [row],
      conflict_target: [:domain],
      on_conflict: [set: Keyword.merge(fields, updated_at: now)]
    )

    :ok
  end

  defp normalise(domain), do: domain |> to_string() |> String.trim() |> String.downcase()

  defp normalise_note(nil), do: nil

  defp normalise_note(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 2000)
    end
  end

  defp trim(nil), do: nil

  defp trim(value) do
    case value |> to_string() |> String.trim() |> String.slice(0, 100) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end

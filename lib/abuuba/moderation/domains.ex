defmodule Abuuba.Moderation.Domains do
  @moduledoc """
  This server's decisions about other servers.

  ## The most specific block wins

  A block on `bad.example` covers `users.bad.example`, or blocking a server
  would be undone by whoever runs it pointing a subdomain at the same machine.
  A block written for `ok.bad.example` beats the wider one for that subdomain
  alone, so an admin can carve one part out of a decision about the rest
  without lifting it.

  Suffix matching is on label boundaries. `notbad.example` is not a subdomain
  of `bad.example` and never matches it, however similar the strings look.

  ## Severity says how far a decision goes

  `silence` takes a domain out of everywhere nobody asked for it, and leaves
  the people who chose to follow somebody there still following them. `suspend`
  cuts it off: nothing is accepted from it, nothing is delivered to it, and the
  accounts here are hidden. `noop` does nothing on its own and exists so a row
  that only rejects media or reports has somewhere to live.

  ## Suspension severs relationships, and that is recorded

  The follows are deleted in both directions, because a suspended domain cannot
  be told about anything and leaving the edges would show people a following
  list of accounts that no longer receive a word from them. What was lost is
  written down and everybody who lost something is told: a follower count that
  drops overnight with no explanation is the failure this record exists to
  prevent.

  Lowering a severity later lifts what the harder one did to the accounts, but
  it does not restore severed relationships. This end cannot recreate consent
  on the other one.

  ## An allowlist is the absence of a decision, not a block

  In limited-federation mode this server talks only to the domains in the
  allowlist. A domain that is not on it is refused without any block existing
  for it, which is why allows live in their own table: folding the two together
  would make an empty allowlist read as a thousand moderation decisions nobody
  took.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Federation.URIs
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.DomainAllow
  alias Abuuba.Moderation.DomainBlock
  alias Abuuba.Moderation.Severance
  alias Abuuba.Moderation.SeveranceEvent
  alias Abuuba.Moderation.Strike
  alias Abuuba.Notifications
  alias Abuuba.Pagination
  alias Abuuba.Relationships.Follow
  alias Abuuba.Relationships.FollowRequest
  alias Abuuba.Repo
  alias Abuuba.Settings

  @csv_header "#domain,#severity,#reject_media,#reject_reports,#public_comment,#obfuscate"

  ## Writing decisions down

  @doc """
  Blocks a domain and applies it to the accounts already here.
  """
  @spec block(Account.t(), map()) :: {:ok, DomainBlock.t()} | {:error, Ecto.Changeset.t()}
  def block(%Account{} = moderator, attrs) do
    with {:ok, block} <- %DomainBlock{} |> DomainBlock.changeset(attrs) |> Repo.insert() do
      apply_block(moderator, block)

      AuditLog.record(moderator, "domain_block.create", :domain_block, block.id, %{
        "domain" => block.domain,
        "severity" => block.severity
      })

      {:ok, block}
    end
  end

  @doc """
  Changes a block and re-applies it.

  Raising the severity applies the harder decision to everybody the block
  covers. Lowering it lifts what the harder one did.
  """
  @spec update_block(Account.t(), DomainBlock.t(), map()) ::
          {:ok, DomainBlock.t()} | {:error, Ecto.Changeset.t()}
  def update_block(%Account{} = moderator, %DomainBlock{} = block, attrs) do
    # The domain itself is not changeable here: a block moved to another domain
    # would leave the first one silenced with nothing on record saying why.
    attrs = Map.drop(attrs, ["domain", :domain])

    with {:ok, updated} <- block |> DomainBlock.changeset(attrs) |> Repo.update() do
      # Only when the severity moved. Re-applying an unchanged suspension would
      # write a second severance event recording a decision nobody took, and
      # the list of what this server has done to people has to stay readable.
      if updated.severity != block.severity do
        lift_beyond(updated.domain, updated.severity)
        apply_block(moderator, updated)
      end

      AuditLog.record(moderator, "domain_block.update", :domain_block, updated.id, %{
        "domain" => updated.domain,
        "severity" => updated.severity
      })

      {:ok, updated}
    end
  end

  @doc """
  Lifts a block.

  What the block did to accounts is undone only where no wider block still
  covers them: lifting the decision about one subdomain must not quietly lift
  the decision about the whole server it sits under.
  """
  @spec unblock(Account.t(), DomainBlock.t()) :: :ok
  def unblock(%Account{} = moderator, %DomainBlock{} = block) do
    Repo.delete(block)

    lift_beyond(block.domain, severity(block.domain))

    AuditLog.record(moderator, "domain_block.undo", :domain_block, block.id, %{
      "domain" => block.domain
    })

    :ok
  end

  @doc """
  Every block, newest first.
  """
  @spec blocks(map()) :: [DomainBlock.t()]
  def blocks(page \\ %{}) do
    DomainBlock
    |> Pagination.window(Map.put_new(page, :limit, 100))
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  @doc """
  One block by id, or `nil`.
  """
  @spec get_block(integer() | String.t()) :: DomainBlock.t() | nil
  def get_block(id) do
    case numeric(id) do
      {:ok, id} -> Repo.get(DomainBlock, id)
      _ -> nil
    end
  end

  @doc """
  The block that applies to a domain, most specific first, or `nil`.
  """
  @spec block_for(String.t() | nil) :: DomainBlock.t() | nil
  def block_for(nil), do: nil

  def block_for(domain) do
    case candidates(domain) do
      [] ->
        nil

      candidates ->
        DomainBlock
        |> where([b], b.domain in ^candidates)
        |> Repo.all()
        |> Enum.max_by(&String.length(&1.domain), fn -> nil end)
    end
  end

  @doc """
  What this server has decided about a domain: `noop`, `silence` or `suspend`.
  """
  @spec severity(String.t() | nil) :: String.t()
  def severity(domain) do
    case block_for(domain) do
      nil -> "noop"
      block -> block.severity
    end
  end

  @doc "Whether a domain is silenced or worse."
  @spec silenced?(String.t() | nil) :: boolean()
  def silenced?(domain), do: severity(domain) in ["silence", "suspend"]

  @doc "Whether a domain is suspended."
  @spec suspended?(String.t() | nil) :: boolean()
  def suspended?(domain), do: severity(domain) == "suspend"

  @doc "Whether attachments from a domain are refused."
  @spec reject_media?(String.t() | nil) :: boolean()
  def reject_media?(domain), do: flag?(domain, :reject_media)

  @doc "Whether reports forwarded from a domain are ignored."
  @spec reject_reports?(String.t() | nil) :: boolean()
  def reject_reports?(domain), do: flag?(domain, :reject_reports)

  @doc """
  Whether this server takes anything from a domain at all.

  One predicate for both the block list and the allowlist, so that nothing has
  to remember to ask twice.
  """
  @spec accepts_from?(String.t() | nil) :: boolean()
  def accepts_from?(nil), do: true

  def accepts_from?(domain) do
    URIs.local_domain?(domain) or (not suspended?(domain) and within_allowlist?(domain))
  end

  @doc """
  Whether this server delivers to a domain.

  A domain we have given up on, or stopped by hand, is refused here too: every
  reason not to send is one question.
  """
  @spec delivers_to?(String.t() | nil) :: boolean()
  def delivers_to?(nil), do: true

  def delivers_to?(domain) do
    accepts_from?(domain) and not Availability.unavailable?(domain)
  end

  @doc """
  The subset of these hosts this server will not deliver to.

  One pair of queries for the whole set. A popular post fans out to thousands
  of followers across a few hundred servers, and asking per follower would be
  thousands of round trips to answer a few hundred questions.
  """
  @spec refused_among([String.t() | nil]) :: MapSet.t()
  def refused_among([]), do: MapSet.new()

  def refused_among(hosts) do
    hosts = hosts |> Enum.reject(&is_nil/1) |> Enum.map(&DomainBlock.normalise/1) |> Enum.uniq()
    names = hosts |> Enum.flat_map(&candidates/1) |> Enum.uniq()

    suspended =
      DomainBlock
      |> where([b], b.domain in ^names and b.severity == "suspend")
      |> select([b], b.domain)
      |> Repo.all()
      |> MapSet.new()

    allowed = allowed_among(names)

    for host <- hosts, refused?(host, suspended, allowed), into: MapSet.new(), do: host
  end

  # `nil` rather than an empty set when the allowlist is off, so that "nothing
  # is allowed" and "everything is" cannot be confused for one another.
  defp allowed_among(names) do
    if limited_federation?() do
      DomainAllow
      |> where([a], a.domain in ^names)
      |> select([a], a.domain)
      |> Repo.all()
      |> MapSet.new()
    end
  end

  defp refused?(host, suspended, allowed) do
    names = candidates(host)

    cond do
      URIs.local_domain?(host) -> false
      Enum.any?(names, &MapSet.member?(suspended, &1)) -> true
      is_nil(allowed) -> false
      true -> not Enum.any?(names, &MapSet.member?(allowed, &1))
    end
  end

  ## The public list

  @doc """
  The blocks anybody may read, with the private notes left out.

  A row that only rejects media is left out entirely: it is a decision about
  this server's own storage rather than a statement about that server for the
  world to read.
  """
  @spec public_blocks() :: [map()]
  def public_blocks do
    DomainBlock
    |> where([b], b.severity in ["silence", "suspend"])
    |> order_by([b], asc: b.domain)
    |> Repo.all()
    |> Enum.map(fn block ->
      %{
        domain: shown_domain(block),
        digest: :crypto.hash(:sha256, block.domain) |> Base.encode16(case: :lower),
        severity: block.severity,
        comment: block.public_comment || ""
      }
    end)
  end

  ## Carrying a list between servers

  @doc """
  Every block as CSV, in the column order shared blocklists use.
  """
  @spec export_csv() :: String.t()
  def export_csv do
    rows =
      DomainBlock
      |> order_by([b], asc: b.domain)
      |> Repo.all()
      |> Enum.map(fn block ->
        Enum.map_join(
          [
            block.domain,
            block.severity,
            to_string(block.reject_media),
            to_string(block.reject_reports),
            block.public_comment || "",
            to_string(block.obfuscate)
          ],
          ",",
          &csv_field/1
        )
      end)

    Enum.join([@csv_header | rows], "\n") <> "\n"
  end

  @doc """
  Reads a CSV blocklist, skipping what it cannot use.

  A shared list is imported again every time it is updated, so a row already
  present is skipped rather than treated as an error. Refusing the whole file
  over one duplicate is what makes somebody stop importing it, and that costs
  more than the duplicate did.
  """
  @spec import_csv(Account.t(), String.t()) ::
          {:ok, %{created: non_neg_integer(), skipped: non_neg_integer()}}
  def import_csv(%Account{} = moderator, csv) do
    result =
      csv
      |> String.split(~r/\R/)
      |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
      |> Enum.map(&parse_csv_row/1)
      |> Enum.reduce(%{created: 0, skipped: 0}, fn attrs, counts ->
        case attrs && block(moderator, attrs) do
          {:ok, _block} -> Map.update!(counts, :created, &(&1 + 1))
          _ -> Map.update!(counts, :skipped, &(&1 + 1))
        end
      end)

    {:ok, result}
  end

  ## The allowlist

  @doc """
  Whether this server talks only to the domains on its allowlist.
  """
  @spec limited_federation?() :: boolean()
  def limited_federation?, do: Settings.get("limited_federation") == true

  @doc """
  Puts a domain on the allowlist.
  """
  @spec allow(Account.t(), String.t()) :: {:ok, DomainAllow.t()} | {:error, Ecto.Changeset.t()}
  def allow(%Account{} = moderator, domain) do
    with {:ok, allowed} <-
           %DomainAllow{} |> DomainAllow.changeset(%{"domain" => domain}) |> Repo.insert() do
      AuditLog.record(moderator, "domain_allow.create", :domain_allow, allowed.id, %{
        "domain" => allowed.domain
      })

      {:ok, allowed}
    end
  end

  @doc """
  Takes a domain off the allowlist.
  """
  @spec disallow(Account.t(), DomainAllow.t()) :: :ok
  def disallow(%Account{} = moderator, %DomainAllow{} = allowed) do
    Repo.delete(allowed)

    AuditLog.record(moderator, "domain_allow.undo", :domain_allow, allowed.id, %{
      "domain" => allowed.domain
    })

    :ok
  end

  @doc """
  Every allowed domain, alphabetically.
  """
  @spec allows(map() | nil) :: [DomainAllow.t()]
  def allows(page \\ nil)

  def allows(nil), do: DomainAllow |> order_by([a], asc: a.domain) |> Repo.all()

  # By id rather than by domain when a page is asked for: a cursor has to be
  # the thing the list is ordered by, and the screens that read the whole list
  # still want it alphabetical.
  def allows(page) do
    DomainAllow
    |> Pagination.window(page)
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  @doc """
  One allowed domain by id, or `nil`.
  """
  @spec get_allow(term()) :: DomainAllow.t() | nil
  def get_allow(id) do
    case numeric(id) do
      {:ok, id} -> Repo.get(DomainAllow, id)
      :error -> nil
    end
  end

  ## Delivery to one instance

  @doc """
  Stops delivering to a domain until somebody says otherwise.

  Separate from the failure counting in `Abuuba.Federation.Availability`: a
  domain given up on after a week of failures comes back the moment it says
  something, and an admin who stopped delivery on purpose did not mean "until
  they say something".
  """
  @spec stop_delivery(Account.t(), String.t()) :: :ok
  def stop_delivery(%Account{} = moderator, domain) do
    Availability.stop(domain)

    AuditLog.record(moderator, "instance.stop_delivery", :domain, 0, %{"domain" => domain})

    :ok
  end

  @doc """
  Starts delivering to a domain again, clearing the failures with it.
  """
  @spec restart_delivery(Account.t(), String.t()) :: :ok
  def restart_delivery(%Account{} = moderator, domain) do
    Availability.restart(domain)

    AuditLog.record(moderator, "instance.restart_delivery", :domain, 0, %{"domain" => domain})

    :ok
  end

  ## Severance

  @doc """
  Every severance event, newest first.
  """
  @spec severance_events(map()) :: [SeveranceEvent.t()]
  def severance_events(page \\ %{}) do
    SeveranceEvent
    |> order_by([e], desc: e.id)
    |> limit(^Map.get(page, :limit, 40))
    |> Repo.all()
  end

  @doc """
  What one local account lost, newest first.
  """
  @spec severed_for(Account.t() | integer(), map()) :: [Severance.t()]
  def severed_for(account, page \\ %{})
  def severed_for(%Account{id: id}, page), do: severed_for(id, page)

  def severed_for(account_id, page) do
    Severance
    |> where([s], s.local_account_id == ^account_id)
    |> order_by([s], desc: s.id)
    |> limit(^Map.get(page, :limit, 100))
    |> Repo.all()
  end

  @doc """
  What one account lost, one entry per decision, newest first.

  Counted here rather than in the caller: the number of relationships an event
  cost this particular person is the only part of it that is theirs, and the
  event row itself says nothing about them.
  """
  @spec severance_summary(Account.t() | integer(), map()) :: [
          %{event: SeveranceEvent.t(), count: non_neg_integer()}
        ]
  def severance_summary(account, page \\ %{})
  def severance_summary(%Account{id: id}, page), do: severance_summary(id, page)

  def severance_summary(account_id, page) do
    Severance
    |> where([s], s.local_account_id == ^account_id)
    |> join(:inner, [s], e in SeveranceEvent, on: e.id == s.relationship_severance_event_id)
    |> group_by([s, e], e.id)
    |> order_by([_s, e], desc: e.id)
    |> limit(^Map.get(page, :limit, 40))
    |> select([s, e], %{event: e, count: count(s.id)})
    |> Repo.all()
  end

  ## Applying

  defp apply_block(moderator, %DomainBlock{severity: "noop"}), do: {:ok, moderator}

  defp apply_block(_moderator, %DomainBlock{severity: "silence"} = block) do
    now = DateTime.utc_now()

    block.domain
    |> accounts_under()
    |> where([a], is_nil(a.silenced_at))
    |> Repo.update_all(set: [silenced_at: now, updated_at: now])

    :ok
  end

  defp apply_block(_moderator, %DomainBlock{severity: "suspend"} = block) do
    now = DateTime.utc_now()

    accounts = block.domain |> accounts_under() |> select([a], a.id) |> Repo.all()

    block.domain
    |> accounts_under()
    |> Repo.update_all(
      set: [
        suspended_at: now,
        silenced_at: now,
        purge_after: DateTime.add(now, Actions.grace_days(), :day),
        updated_at: now
      ]
    )

    sever(block.domain, accounts)

    :ok
  end

  # Lifts whatever a severity no longer justifies, for the accounts that no
  # other block still covers. Asked per account rather than per domain, because
  # an account on `ok.bad.example` may be covered by a wider block on
  # `bad.example` that has not moved.
  defp lift_beyond(domain, severity) do
    for account <- domain |> accounts_under() |> Repo.all(),
        effective = severity_for_account(account, domain, severity),
        changes = lifted_fields(effective, standing_action(account)),
        changes != [] do
      Accounts.update_moderation(account, Map.new(changes))
    end

    :ok
  end

  # What a moderator decided about this one account, apart from any domain
  # block. Lifting the wider decision must not quietly undo the narrower one
  # nobody revisited.
  defp standing_action(%Account{id: id}) do
    Strike
    |> where([s], s.target_account_id == ^id and is_nil(s.overruled_at))
    |> where([s], s.action in ["silence", "suspend"])
    |> select([s], s.action)
    |> Repo.all()
    |> Enum.max_by(&DomainBlock.rank/1, fn -> "noop" end)
  end

  # The severity that still applies to one account once the block being changed
  # carries `severity`: the strongest of it and anything else covering them.
  defp severity_for_account(%Account{domain: account_domain}, changed_domain, severity) do
    others =
      account_domain
      |> candidates()
      |> Enum.reject(&(&1 == changed_domain))

    strongest =
      DomainBlock
      |> where([b], b.domain in ^others)
      |> select([b], b.severity)
      |> Repo.all()
      |> Enum.max_by(&DomainBlock.rank/1, fn -> "noop" end)

    Enum.max_by([severity, strongest], &DomainBlock.rank/1)
  end

  # The strongest of what the domain still says and what was decided about this
  # account on its own.
  defp lifted_fields(from_domain, from_account) do
    case Enum.max_by([from_domain, from_account], &DomainBlock.rank/1) do
      "suspend" -> []
      "silence" -> [suspended_at: nil, purge_after: nil]
      _noop -> [suspended_at: nil, purge_after: nil, silenced_at: nil]
    end
  end

  # Both directions. A suspended domain cannot be told about anything, and
  # leaving the edges in place would show people a following list of accounts
  # that no longer receive a word from them.
  defp sever(domain, remote_ids) do
    {:ok, event} =
      %SeveranceEvent{}
      |> SeveranceEvent.changeset(%{type: "domain_block", target_name: domain})
      |> Repo.insert()

    active = edges_between(remote_ids, :active)
    passive = edges_between(remote_ids, :passive)

    record_severed(event, active, "active")
    record_severed(event, passive, "passive")

    delete_edges(remote_ids)

    tell_about_severance(active ++ passive)

    :ok
  end

  # The server did this rather than a person, so the notification comes from
  # the instance actor. Fetched once: it is the same actor for everybody.
  defp tell_about_severance([]), do: :ok

  defp tell_about_severance(edges) do
    from_id = InstanceActor.fetch!().id

    edges
    |> Enum.map(fn {local_id, _remote_id} -> local_id end)
    |> Enum.uniq()
    |> Enum.each(&Notifications.notify(&1, from_id, "severed_relationships"))
  end

  defp edges_between(remote_ids, :active) do
    Follow
    |> where([f], f.target_account_id in ^remote_ids)
    |> join(:inner, [f], a in Account, on: a.id == f.account_id)
    |> where([_f, a], is_nil(a.domain))
    |> select([f], {f.account_id, f.target_account_id})
    |> Repo.all()
  end

  defp edges_between(remote_ids, :passive) do
    Follow
    |> where([f], f.account_id in ^remote_ids)
    |> join(:inner, [f], a in Account, on: a.id == f.target_account_id)
    |> where([_f, a], is_nil(a.domain))
    |> select([f], {f.target_account_id, f.account_id})
    |> Repo.all()
  end

  defp record_severed(_event, [], _direction), do: :ok

  defp record_severed(event, edges, direction) do
    now = DateTime.utc_now()

    rows =
      Enum.map(edges, fn {local_id, remote_id} ->
        %{
          relationship_severance_event_id: event.id,
          local_account_id: local_id,
          remote_account_id: remote_id,
          direction: direction,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Severance, rows, on_conflict: :nothing)

    :ok
  end

  defp delete_edges(remote_ids) do
    for schema <- [Follow, FollowRequest] do
      schema
      |> where([f], f.account_id in ^remote_ids or f.target_account_id in ^remote_ids)
      |> Repo.delete_all()
    end

    :ok
  end

  ## Matching

  # A domain and every parent it sits under, so one query answers "is anything
  # here written down".
  defp candidates(nil), do: []

  defp candidates(domain) do
    domain
    |> DomainBlock.normalise()
    |> String.split(".")
    |> case do
      labels when length(labels) < 2 -> [Enum.join(labels, ".")]
      labels -> suffixes(labels)
    end
    |> Enum.reject(&(&1 == ""))
  end

  defp suffixes(labels) do
    # `a.b.c` gives `a.b.c`, `b.c`, `c`. The last is a bare TLD, which nobody
    # can register a block for anyway, and dropping it here would cost a
    # special case for two-label domains.
    0..(length(labels) - 1)
    |> Enum.map(fn drop -> labels |> Enum.drop(drop) |> Enum.join(".") end)
  end

  defp accounts_under(domain) do
    like = "%." <> domain

    from(a in Account,
      where: not is_nil(a.domain),
      where:
        fragment("lower(?)", a.domain) == ^domain or like(fragment("lower(?)", a.domain), ^like)
    )
  end

  defp flag?(domain, field) do
    case block_for(domain) do
      nil -> false
      block -> Map.fetch!(block, field)
    end
  end

  defp within_allowlist?(domain) do
    if limited_federation?() do
      names = candidates(domain)

      names != [] and DomainAllow |> where([a], a.domain in ^names) |> Repo.exists?()
    else
      true
    end
  end

  ## Presentation

  # The first and last labels stay, everything between them becomes asterisks.
  # Enough for somebody who already knows the server to recognise it, not
  # enough to be a signpost for everybody else.
  defp shown_domain(%DomainBlock{obfuscate: false, domain: domain}), do: domain

  defp shown_domain(%DomainBlock{domain: domain}) do
    case String.split(domain, ".") do
      [single] ->
        obfuscate_label(single)

      labels ->
        {leading, [last]} = Enum.split(labels, -1)

        Enum.join(Enum.map(leading, &obfuscate_label/1) ++ [last], ".")
    end
  end

  defp obfuscate_label(label) when byte_size(label) <= 2, do: String.duplicate("*", 2)

  defp obfuscate_label(label) do
    String.first(label) <> String.duplicate("*", String.length(label) - 1)
  end

  ## CSV

  defp parse_csv_row(line) do
    case csv_fields(line) do
      [domain | rest] ->
        attrs = %{
          "domain" => domain,
          "severity" => Enum.at(rest, 0) || "silence",
          "reject_media" => truthy(Enum.at(rest, 1)),
          "reject_reports" => truthy(Enum.at(rest, 2)),
          "public_comment" => Enum.at(rest, 3) || "",
          "obfuscate" => truthy(Enum.at(rest, 4))
        }

        if String.trim(domain) == "", do: nil, else: attrs

      _ ->
        nil
    end
  end

  # Enough CSV for a blocklist: quoted fields with commas in them, and doubled
  # quotes inside a quoted field. Not a general parser, and it does not need to
  # be for a two-column-plus-comment file.
  defp csv_fields(line), do: csv_fields(String.graphemes(line), "", [], false)

  defp csv_fields([], current, done, _quoted), do: Enum.reverse([current | done])

  defp csv_fields(["\"", "\"" | rest], current, done, true),
    do: csv_fields(rest, current <> "\"", done, true)

  defp csv_fields(["\"" | rest], current, done, quoted),
    do: csv_fields(rest, current, done, not quoted)

  defp csv_fields(["," | rest], current, done, false),
    do: csv_fields(rest, "", [current | done], false)

  defp csv_fields([char | rest], current, done, quoted),
    do: csv_fields(rest, current <> char, done, quoted)

  defp csv_field(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp truthy(value), do: String.downcase(to_string(value)) in ["true", "1", "yes"]

  defp numeric(value) when is_integer(value), do: {:ok, value}

  defp numeric(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp numeric(_value), do: :error
end

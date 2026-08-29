defmodule Abuuba.Accounts.LinkVerification do
  @moduledoc """
  Earning the tick beside a link on a local profile.

  Anybody can type any URL into a profile field. What makes one worth a badge
  is that the page at the other end links back with `rel="me"`, because putting
  that link there requires control of the page. So this server fetches the page
  and looks for itself in it; the badge is this server's assertion, never the
  account's, which is why `verified_at` is unreachable from any changeset that
  handles user input.

  ## What counts as a link back

  An `<a>` or `<link>` whose `rel` carries the token `me`, pointing at either
  the profile page or the ActivityPub actor id. Both name the same account and
  people link whichever one their client showed them.

  A `rel="me"` that redirects to one of those counts too. Identity services and
  short links are a normal way to publish the link, and refusing them would
  fail exactly the people who took the trouble.

  ## Failure is not disproof

  A stamp is cleared when the page was read and the link back was not in it,
  and kept when the page could not be read at all. A site being down for an
  afternoon is not evidence that somebody took their link down, and treating it
  as such would flicker the badge on every outage.

  ## One host at a time

  Everybody links to the same handful of sites, so a sweep across a few
  thousand accounts is a few thousand requests to a few dozen hosts. The rate
  limit here bounds what any one of them sees from us; a field it stops is
  deferred rather than failed, and the worker snoozes so the check happens a
  minute later instead of being lost.

  ## Remote accounts are not ours to verify

  Their server asserts their badges and we display them. Fetching on their
  behalf would let any remote actor aim this server at any URL it likes.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.HTTP
  alias Abuuba.Federation.URIs
  alias Abuuba.RateLimit
  alias Abuuba.Repo

  # Long enough that a popular host is not fetched again the same week, short
  # enough that a link taken down loses its badge while anybody still cares.
  @recheck_after_days 7

  @per_host_limit 5
  @per_host_window_ms 60_000

  # One sweep's worth. The queue would take the whole table happily enough; the
  # bound is so that an instance with a large backlog spreads it over hours
  # instead of filling the queue in one minute.
  @sweep_batch 500

  @doc """
  Checks every link on a local profile and records what it found.

  Returns `{:defer, account}` when something was left unchecked and is worth
  coming back for shortly: a host that had had enough of us for the moment, or
  a field that appeared while this was running. Everything decided is still
  saved either way — a deferral is about one field, not about the account.
  """
  @spec verify(Account.t(), keyword()) :: {:ok, Account.t()} | {:defer, Account.t()}
  def verify(account, opts \\ [])

  def verify(%Account{domain: nil, fields: fields} = account, opts) when fields != [] do
    now = DateTime.utc_now()
    targets = targets(account)
    checked = Enum.map(fields, &check(&1, targets, now, opts))

    {account, unseen?} = save(account, Enum.map(checked, fn {field, _outcome} -> field end))

    if unseen? or Enum.any?(checked, fn {_field, outcome} -> outcome == :deferred end) do
      {:defer, account}
    else
      {:ok, account}
    end
  end

  def verify(%Account{} = account, _opts), do: {:ok, account}

  @doc """
  Local accounts whose links have not been looked at lately.

  A field with no `checked_at` has never been looked at, which covers both a
  link somebody added a minute ago and every row that existed before this
  server knew how to check one.
  """
  @spec due(DateTime.t()) :: [Account.t()]
  def due(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@recheck_after_days, :day)

    from(a in Account,
      where: is_nil(a.domain) and is_nil(a.suspended_at),
      # Cheap and first: most accounts have no fields at all, and this keeps
      # them from paying for the row-expanding check below.
      where: fragment("jsonb_array_length(?) > 0", a.fields),
      where:
        fragment(
          """
          EXISTS (
            SELECT 1 FROM jsonb_array_elements(?) AS f
            WHERE f->>'checked_at' IS NULL OR (f->>'checked_at')::timestamptz < ?
          )
          """,
          a.fields,
          ^cutoff
        ),
      order_by: [asc: a.id],
      limit: @sweep_batch,
      # Only what queueing a job needs. The rest of an account is a bio, an
      # avatar and thirty other columns, and the sweep would carry all of it
      # for five hundred rows an hour to read three fields.
      select: [:id, :domain, :fields]
    )
    |> Repo.all()
  end

  @doc """
  How many pages this server will read from one host inside the window.
  """
  @spec per_host_limit() :: pos_integer()
  def per_host_limit, do: @per_host_limit

  @doc """
  Whether a field's value is a URL this server is willing to fetch at all.

  Deliberately narrow. HTTPS only, no credentials in the URL, and a host that
  is already in its normal form: a display that shows one host while the fetch
  goes to another is the whole point of a verification badge undone.
  """
  @spec verifiable?(String.t() | nil) :: boolean()
  def verifiable?(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        normal_host?(host)

      _ ->
        false
    end
  end

  def verifiable?(_value), do: false

  # Punycode passes, an IDN in its unicode form does not. Both spellings reach
  # the same server, so accepting only one of them is not a restriction on who
  # may verify a link, only on which spelling this server compares.
  defp normal_host?(host) do
    host == String.downcase(host) and String.match?(host, ~r/\A[a-z0-9.\-]+\z/)
  end

  ## One field

  defp check(field, targets, now, opts) do
    url = String.trim(field.value || "")

    cond do
      fresh?(field, now) ->
        # Looked at within the window, so there is nothing to learn by asking
        # again. This is what keeps somebody who saves their profile twice in
        # an afternoon from sending two rounds of requests at every site they
        # link to: the trigger is the save, but the budget is the clock.
        {field, :checked}

      not verifiable?(url) ->
        # Not a link this server can check, so there is nothing it can be
        # standing behind. Clearing is the point: a value edited from a
        # verified https link to something else must not keep the badge.
        {%{field | verified_at: nil, checked_at: now}, :checked}

      not allowed?(url) ->
        {field, :deferred}

      true ->
        {stamp(field, read(url, targets, opts), now), :checked}
    end
  end

  defp fresh?(%{checked_at: nil}, _now), do: false

  defp fresh?(%{checked_at: checked_at}, now) do
    DateTime.diff(now, checked_at, :day) < @recheck_after_days
  end

  # `checked_at` moves whatever was found, including when the page could not be
  # read: a host that is down for good would otherwise have every sweep queue a
  # fetch at it forever. Only `verified_at` distinguishes the three outcomes,
  # and only a page we actually read can clear it.
  defp stamp(field, :links_back, now), do: %{field | verified_at: now, checked_at: now}
  defp stamp(field, :no_link_back, now), do: %{field | verified_at: nil, checked_at: now}
  defp stamp(field, :unreadable, now), do: %{field | checked_at: now}

  defp read(url, targets, opts) do
    case HTTP.get_document(url, Keyword.put(opts, :accept, HTTP.browser_accept())) do
      {:ok, %{body: body, url: final_url}} ->
        if links_back?(body, final_url, targets, opts), do: :links_back, else: :no_link_back

      {:error, _reason} ->
        :unreadable
    end
  end

  defp links_back?(body, page_url, targets, opts) do
    hrefs = rel_me_hrefs(body, page_url)

    Enum.any?(hrefs, &(normalise(&1) in targets)) or redirects_back?(hrefs, targets, opts)
  end

  # `~=` is the attribute selector for a whitespace-separated token list and
  # `i` folds its case, which is exactly the rule: `rel="me nofollow"` and
  # `rel="ME"` are links back, `rel="memento"` is not. Done in the selector so
  # that a page with a thousand `rel="nofollow"` links never crosses into
  # Elixir terms.
  defp rel_me_hrefs(body, page_url) do
    body
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s|a[rel~="me" i], link[rel~="me" i]|)
    |> LazyHTML.attribute("href")
    # An empty or fragment-only href resolves to the page it is on, which is
    # never a link back to anywhere and would make a page look like it points
    # at whatever we happened to fetch.
    |> Enum.reject(&(String.trim(to_string(&1)) in ["", "#"]))
    |> Enum.map(&URIs.absolute(&1, page_url))
    |> Enum.reject(&is_nil/1)
  end

  # One extra request at most, and only ever the first hop of it. Asked with a
  # HEAD that does not follow, so the question is "where does this point"
  # rather than "what is there": this server never fetches the page at the
  # other end, and a chain somebody built to make us fetch things stops after
  # one link.
  #
  # The candidate is the first *fetchable* href rather than the first href,
  # because `<a rel="me" href="mailto:...">` is an ordinary thing to have on a
  # personal page and taking it literally would spend the one hop on something
  # that can never be a redirect.
  #
  # The budget is charged against the host in the markup, not against the host
  # whose profile field started this. Otherwise a page under an attacker's
  # control names any third party it likes and this server becomes an
  # unmetered HEAD reflector at it, one request per profile they can edit.
  defp redirects_back?(hrefs, targets, opts) do
    case Enum.find(hrefs, &verifiable?/1) do
      nil ->
        false

      href ->
        allowed?(href) and hop_lands_on?(href, targets, opts)
    end
  end

  defp hop_lands_on?(href, targets, opts) do
    case HTTP.redirect_hop(href, Keyword.put(opts, :accept, HTTP.browser_accept())) do
      {:ok, location} -> normalise(location) in targets
      {:error, _reason} -> false
    end
  end

  ## Comparing URLs

  defp targets(account) do
    [URIs.profile_url(account), URIs.actor_uri(account)]
    |> Enum.map(&normalise/1)
    |> Enum.uniq()
  end

  # Compared case-folded whole, path included, and with a trailing slash
  # ignored. Case-folding a path would be wrong for a stranger's URL, where
  # `/A` and `/a` are routinely two pages, but the only URLs compared here are
  # this server's own, and a local username is unique case-insensitively, so
  # `/@Alice` and `/@alice` cannot be two people. Somebody who typed their own
  # handle with a capital gets their badge instead of a mystery.
  defp normalise(url) when is_binary(url) do
    url |> String.trim() |> String.downcase() |> String.trim_trailing("/")
  end

  defp normalise(_url), do: nil

  ## The per-host budget

  # `verifiable?/1` has already proved there is a host, so there is no bucket
  # for URLs without one.
  defp allowed?(url) do
    host = URIs.host_of(url)

    match?(
      {:ok, _remaining},
      RateLimit.hit("rel_me:" <> host, limit: @per_host_limit, window_ms: @per_host_window_ms)
    )
  end

  # Written back onto the row as it stands now, not onto the snapshot this job
  # started from. Checking a profile takes as long as the slowest site on it,
  # and its owner may well save a new link in that time; writing the snapshot
  # back would silently undo their edit, and they would have been told it
  # saved. So the row is re-read under a lock and the outcomes are matched onto
  # it by value: a field that is still there gets its stamp, one that was
  # edited or deleted while we were reading gets nothing, and the next job
  # looks at whatever replaced it.
  #
  # The equality check is not only an optimisation. An embed with no primary
  # key is replaced wholesale rather than diffed, so Ecto sees a change even
  # when nothing differs, and the deferred path — snooze, come back a minute
  # later, defer again — would rewrite the row forever.
  # The second element says whether the row now holds a field this run never
  # saw, which is how an edit made while the fetches were in flight gets
  # noticed: the caller asks to be run again rather than leaving a new link
  # unchecked until the weekly sweep.
  @spec save(Account.t(), [struct()]) :: {Account.t(), boolean()}
  defp save(account, fields) do
    outcomes = Map.new(fields, &{&1.value, &1})

    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.one(from(a in Account, where: a.id == ^account.id, lock: "FOR UPDATE")) do
          nil ->
            # Deleted while we were reading somebody's web site.
            {account, false}

          current ->
            merged = Enum.map(current.fields, &Map.get(outcomes, &1.value, &1))
            unseen? = Enum.any?(current.fields, &(not Map.has_key?(outcomes, &1.value)))

            {write(current, merged), unseen?}
        end
      end)

    result
  end

  defp write(account, fields) do
    if fields == account.fields do
      account
    else
      account |> Account.link_verification_changeset(fields) |> Repo.update!()
    end
  end
end

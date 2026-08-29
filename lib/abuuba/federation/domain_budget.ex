defmodule Abuuba.Federation.DomainBudget do
  @moduledoc """
  How many distinct subdomains one host is allowed to introduce us to.

  Anybody can put an actor on `a.evil.example`, `b.evil.example`, and so on
  without limit. Each one we accept costs us a row, a keypair and eventually a
  timeline's worth of posts, and costs them a DNS wildcard. Without a budget
  that asymmetry is the whole attack.

  The budget is per registrable domain rather than per host, or the attack is
  simply to use a new host each time.

  ## The registrable domain is approximate on purpose

  Working out `example.co.uk` from `a.b.example.co.uk` needs the public suffix
  list, which is a large file that changes and would have to be shipped and
  updated. The approximation here takes the last two labels, and three when the
  second-to-last is one of the handful of common two-part suffixes.

  That is wrong sometimes, and the direction it is wrong in matters: for an
  unlisted two-part suffix it treats sibling domains as one budget, which is
  stricter than reality rather than looser. Being too strict costs a legitimate
  server one refused discovery; being too loose costs us the whole defence.
  """

  import Ecto.Query

  alias Abuuba.Repo

  @max_subdomains 10

  # Enough of the common two-part suffixes to keep the ordinary cases right.
  # Not a public suffix list and not trying to be one; see the module doc for
  # why being wrong here is safe in the direction it is wrong in.
  @two_part_suffixes ~w(co ac com net org gov edu gob mil or ne go in gr gen ltd plc gouv)

  @doc """
  Whether this host may introduce another actor, counting one if so.

  Counted rather than merely checked, because the count is the budget: asking
  without spending would let an attacker discover the limit without paying it.
  """
  @spec spend(String.t()) :: :ok | {:error, :domain_budget_exhausted}
  def spend(domain) do
    registrable = registrable_domain(domain)

    if known_subdomain?(domain) do
      # Already discovered, so this costs nothing new.
      :ok
    else
      increment(registrable)
    end
  end

  defp increment(registrable) do
    now = DateTime.utc_now()

    {_count, [%{subdomain_count: count}]} =
      Repo.insert_all(
        "domain_discoveries",
        [
          [
            registrable_domain: registrable,
            subdomain_count: 1,
            inserted_at: now,
            updated_at: now
          ]
        ],
        conflict_target: [:registrable_domain],
        on_conflict: [inc: [subdomain_count: 1], set: [updated_at: now]],
        returning: [:subdomain_count]
      )

    if count > @max_subdomains do
      {:error, :domain_budget_exhausted}
    else
      :ok
    end
  end

  @doc """
  The domain a budget is kept against.
  """
  @spec registrable_domain(String.t()) :: String.t()
  def registrable_domain(domain) do
    labels = domain |> String.downcase() |> String.trim_trailing(".") |> String.split(".")

    case Enum.reverse(labels) do
      [tld, second, third | _rest] when second in @two_part_suffixes ->
        Enum.join([third, second, tld], ".")

      [tld, second | _rest] ->
        Enum.join([second, tld], ".")

      _short ->
        Enum.join(labels, ".")
    end
  end

  @doc """
  How many subdomains a registrable domain has spent.
  """
  @spec spent(String.t()) :: non_neg_integer()
  def spent(domain) do
    registrable = registrable_domain(domain)

    from(d in "domain_discoveries",
      where: d.registrable_domain == ^registrable,
      select: d.subdomain_count
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  The number of distinct subdomains one registrable domain may introduce.
  """
  def max_subdomains, do: @max_subdomains

  # A host we already hold an account for is not a new discovery, so refreshing
  # an actor never spends budget.
  defp known_subdomain?(domain) do
    from(a in "accounts", where: a.domain == ^String.downcase(domain), select: 1, limit: 1)
    |> Repo.one()
    |> is_integer()
  end
end

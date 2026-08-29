defmodule Abuuba.ActionLimits do
  @moduledoc """
  How much of a thing one account may do, as opposed to how fast.

  Named apart from `Abuuba.RateLimit` on purpose: that one is the counter, this
  one is the policy. These are not the API's request limits, which are about
  load and live in `AbuubaWeb.Plugs.APIRateLimit`. These bound the *action*, however it was
  reached, and they exist because the actions are abusive in volume rather than
  in themselves: three hundred posts in three hours is a spam run, and four
  hundred follows in a day is somebody building a follower list by following
  everybody and unfollowing whoever does not follow back.

  Counted per account rather than per token or per address. A person with six
  apps has one budget, and moving to a new IP does not reset it.

  The numbers are the reference implementation's, so an account that behaves
  acceptably there behaves acceptably here.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.RateLimit

  @hour 60 * 60 * 1000

  @families %{
    statuses: {300, 3 * @hour},
    follows: {400, 24 * @hour},
    reports: {400, 24 * @hour},
    # Not the reference implementation's, because it has no equivalent. This
    # one writes to people who never signed up here, so the number is what a
    # person with something to say needs and no more: a few a day is a
    # newsletter, and a few an hour is what somebody does to a list they bought.
    email_updates: {4, 24 * @hour}
  }

  @doc """
  Counts one action against an account's budget.

  Returns `:ok`, or `{:error, :rate_limited}` with nothing counted against the
  caller beyond the attempt itself.
  """
  @spec take(Account.t() | integer(), atom()) :: :ok | {:error, :rate_limited}
  def take(%Account{id: account_id}, family), do: take(account_id, family)

  def take(account_id, family) do
    {limit, window} = Map.fetch!(@families, family)

    case RateLimit.hit("#{family}:account:#{account_id}", limit: limit, window_ms: window) do
      {:ok, _remaining} -> :ok
      error -> error
    end
  end

  @doc """
  The limit and window for a family, for anybody that has to describe them.
  """
  @spec family(atom()) :: {pos_integer(), pos_integer()}
  def family(name), do: Map.fetch!(@families, name)
end

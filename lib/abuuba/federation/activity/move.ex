defmodule Abuuba.Federation.Activity.Move do
  @moduledoc """
  Somebody moved their account to another server, and wants their followers to
  come along.

  This is the most abusable activity in the protocol, because what it asks for
  is "make everybody who follows me follow this other account instead". Three
  things guard it.

  **The target has to claim the source back.** The new account's `alsoKnownAs`
  must list the old one. That is the consent half: without it, anybody could
  publish a `Move` naming any account as the origin and inherit its followers.
  The backlink is checked by fetching the target's own actor document, not by
  believing the activity.

  **A cooldown.** Moving repeatedly is how somebody drags a follower list
  around the network faster than anybody can notice, so an account that moved
  recently cannot move again.

  **Only local followers are moved.** Followers on other servers are their
  servers' business, and re-following on their behalf would be doing to them
  exactly what this handler exists to prevent.
  """

  alias Abuuba.Accounts
  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Relationships
  alias Abuuba.Repo

  @cooldown_days 7

  @doc false
  def handle(activity, opts \\ []) do
    with {:ok, origin} <- Helpers.actor(activity, opts),
         target_uri when is_binary(target_uri) <- Helpers.uri_of(activity["target"]),
         :ok <- check_cooldown(origin),
         {:ok, target} <- Helpers.resolve(target_uri, opts),
         :ok <- check_backlink(target, origin) do
      move(origin, target)
    else
      _ -> :ok
    end
  end

  # An account that moved recently cannot move again. Without this, a chain of
  # moves walks a follower list across the network faster than a moderator can
  # follow it.
  defp check_cooldown(%{moved_at: nil}), do: :ok

  defp check_cooldown(%{moved_at: at}) do
    if DateTime.diff(DateTime.utc_now(), at, :day) >= @cooldown_days do
      :ok
    else
      {:error, :moved_too_recently}
    end
  end

  # The consent half. The target's own actor document has to name the origin in
  # alsoKnownAs, or anybody could publish a Move claiming any account as its
  # origin and inherit that account's followers.
  defp check_backlink(target, origin) do
    aliases = target.also_known_as || []

    if origin.uri in aliases do
      :ok
    else
      {:error, :no_backlink}
    end
  end

  defp move(origin, target) do
    {:ok, _} =
      Accounts.update_account(origin, %{
        moved_to_account_id: target.id,
        moved_at: DateTime.utc_now()
      })

    origin
    |> Relationships.follower_ids()
    |> Enum.map(&Repo.get(Abuuba.Accounts.Account, &1))
    |> Enum.filter(&local?/1)
    |> Enum.each(&refollow(&1, origin, target))

    :ok
  end

  defp local?(nil), do: false
  defp local?(account), do: is_nil(account.domain)

  # Follow first, then unfollow. The other order leaves somebody following
  # nobody if the second step fails, and following both for a moment is a much
  # smaller wrong than following neither.
  defp refollow(follower, origin, target) do
    Relationships.follow(follower, target)
    Relationships.unfollow(follower, origin)
  end

  @doc """
  How long an account must wait between moves.
  """
  def cooldown_days, do: @cooldown_days
end

defmodule Abuuba.Moderation.AuditLog do
  @moduledoc """
  What moderators have done, and to what.

  ## Why it is not a debugging aid

  It is what one moderator reads to find out what another already decided, what
  an account's owner is answered with when they ask why they were suspended,
  and what an appeal is judged against. A moderation team without it is a team
  where every decision has to be remembered by whoever made it.

  ## Append only

  Nothing here is edited or deleted. A log somebody can tidy is a log nobody
  can rely on, and the whole value is that it says what happened rather than
  what somebody would prefer had happened.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Repo

  @doc """
  Records one action.

  Takes the moderator, a verb, and what it was done to. `nil` for the moderator
  means the server acted on its own, which is worth being able to tell apart
  from somebody deciding.
  """
  @spec record(Account.t() | integer() | nil, String.t(), atom() | String.t(), integer(), map()) ::
          :ok
  def record(actor, action, target_type, target_id, details \\ %{}) do
    now = DateTime.utc_now()

    Repo.insert_all("audit_log_entries", [
      [
        account_id: account_id(actor),
        # Written into the row rather than joined at read time. An entry is
        # read when somebody asks what happened, which is most often after the
        # account it happened to has been deleted, and two dangling integers
        # cannot answer who did what to whom. The handle at the time is also
        # more truthful than a join: somebody renamed since is not who the
        # entry was written about.
        account_handle: handle(actor),
        action: to_string(action),
        target_type: to_string(target_type),
        target_id: target_id,
        target_label: label(target_type, target_id, details),
        details: details,
        inserted_at: now,
        updated_at: now
      ]
    ])

    :ok
  end

  @doc """
  Everything that has happened to one thing, oldest first.

  Oldest first because it is read as a story: what was done, then what was done
  next.
  """
  @spec for_target(atom() | String.t(), integer()) :: [map()]
  def for_target(target_type, target_id) do
    from(e in "audit_log_entries",
      where: e.target_type == ^to_string(target_type) and e.target_id == ^target_id,
      order_by: [asc: e.id],
      select: %{
        id: e.id,
        account_id: e.account_id,
        action: e.action,
        details: e.details,
        inserted_at: e.inserted_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Everything one moderator has done, newest first.
  """
  @spec by_actor(Account.t() | integer(), map()) :: [map()]
  def by_actor(actor, page \\ %{}) do
    from(e in "audit_log_entries",
      # `nil` asks for what the server did on its own, which is a real question:
      # somebody coming back to a setting that changed itself has to be able to
      # find out why.
      where: ^actor_condition(account_id(actor)),
      order_by: [desc: e.id],
      limit: ^Map.get(page, :limit, 40),
      select: %{
        id: e.id,
        action: e.action,
        target_type: e.target_type,
        target_id: e.target_id,
        details: e.details,
        inserted_at: e.inserted_at
      }
    )
    |> Repo.all()
  end

  # What the target was called, for the log to still read once it is gone.
  # Accounts get their handle; anything else names its own kind and id, or
  # whatever the action wrote down about it.
  defp label(target_type, target_id, details) do
    case to_string(target_type) do
      "account" -> account_handle(target_id) || "account ##{target_id}"
      "domain" <> _rest -> Map.get(details, "domain") || "domain ##{target_id}"
      other -> Map.get(details, "label") || "#{other} ##{target_id}"
    end
  end

  defp account_handle(nil), do: nil

  defp account_handle(id) do
    case Repo.get(Account, id) do
      nil -> nil
      account -> Account.acct(account)
    end
  end

  defp handle(nil), do: nil
  defp handle(%Account{} = account), do: Account.acct(account)
  defp handle(id) when is_integer(id), do: account_handle(id)

  defp actor_condition(nil), do: dynamic([e], is_nil(e.account_id))
  defp actor_condition(id), do: dynamic([e], e.account_id == ^id)

  defp account_id(nil), do: nil
  defp account_id(%Account{id: id}), do: id
  defp account_id(id) when is_integer(id), do: id
end

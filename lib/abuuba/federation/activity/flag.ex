defmodule Abuuba.Federation.Activity.Flag do
  @moduledoc """
  Another server reported one of our accounts to us.

  Recorded rather than acted on. A report is somebody's opinion arriving from
  a server whose moderation standards are their own, so it goes into the queue
  a moderator here reads and nothing happens automatically.

  A `Flag` names one account and any number of its posts. The account is what
  the report is against; the posts are evidence.
  """

  import Ecto.Query

  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Moderation.Domains
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status

  # Long enough for a real explanation, short enough that a report cannot be
  # used to write a novel into our database.
  @max_comment 5_000

  @doc false
  def handle(activity, opts \\ []) do
    with {:ok, reporter} <- Helpers.actor(activity, opts),
         false <- Domains.reject_reports?(reporter.domain),
         {target, status_ids} when not is_nil(target) <- subjects(activity) do
      record(activity, reporter, target, status_ids)
    else
      _ -> :ok
    end
  end

  # The object is a list mixing the account and its posts, and which is which
  # is decided by looking them up rather than by their order.
  defp subjects(activity) do
    uris =
      activity["object"] |> List.wrap() |> Enum.map(&Helpers.uri_of/1) |> Enum.reject(&is_nil/1)

    target =
      uris
      |> Enum.map(&Helpers.local_account/1)
      |> Enum.find(&(not is_nil(&1)))

    status_ids =
      Status
      |> where([s], s.uri in ^uris and s.local == true)
      |> select([s], s.id)
      |> Repo.all()

    {target, status_ids}
  end

  defp record(activity, reporter, target, status_ids) do
    uri = activity["id"]

    if uri && already_recorded?(uri) do
      # A redelivery. The moderator has already been given this one.
      :ok
    else
      insert(uri, reporter, target, status_ids, activity["content"])
    end
  end

  defp already_recorded?(uri) do
    Repo.exists?(from r in "reports", where: r.uri == ^uri)
  end

  defp insert(uri, reporter, target, status_ids, comment) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "reports",
      [
        [
          account_id: reporter.id,
          target_account_id: target.id,
          comment: truncate(comment),
          uri: uri,
          forwarded: false,
          status_ids: status_ids,
          inserted_at: now,
          updated_at: now
        ]
      ],
      on_conflict: :nothing,
      conflict_target: [:uri]
    )

    :ok
  end

  defp truncate(comment) when is_binary(comment), do: String.slice(comment, 0, @max_comment)
  defp truncate(_comment), do: ""

  @doc """
  How much of a report's comment is kept.
  """
  def max_comment, do: @max_comment
end

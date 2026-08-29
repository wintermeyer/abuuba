defmodule Abuuba.Federation.Activity.Announce do
  @moduledoc """
  Somebody boosted something.

  The boosted object has to be fetched if we do not hold it, and that fetch is
  the point of the activity: a boost of something nobody here has ever seen is
  how a post travels beyond the servers that already follow its author.

  A boost carries its own audience, not the original's. Boosting a post to
  followers-only is a real thing people do, and taking the original's
  visibility would leak it.
  """

  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.JSONLD
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Statuses

  @public JSONLD.public()

  @doc false
  def handle(activity, opts \\ []) do
    with {:ok, booster} <- Helpers.actor(activity, opts),
         {:ok, original} <- boosted_status(activity, opts) do
      boost(booster, original, activity)
    else
      {:error, reason} when reason in [:untrustworthy_attribution, :not_found, :gone] -> :ok
      error -> error
    end
  end

  defp boosted_status(activity, opts) do
    case Helpers.object(activity) do
      # Embedded rather than referenced: some servers send the whole object,
      # which saves a fetch.
      %{} = embedded -> ResolveStatus.from_document(embedded, opts)
      _ -> resolve_by_uri(activity, opts)
    end
  end

  defp resolve_by_uri(activity, opts) do
    case Helpers.uri_of(activity["object"]) do
      nil -> {:error, :object_missing}
      uri -> ResolveStatus.resolve(uri, opts)
    end
  end

  defp boost(booster, original, activity) do
    case Statuses.boost(booster, %{original | visibility: visibility(activity)}) do
      {:ok, _boost} -> :ok
      # Already boosted. A redelivery, which is ordinary.
      {:error, %Ecto.Changeset{}} -> :ok
      error -> error
    end
  end

  defp visibility(activity) do
    to = list(activity["to"])
    cc = list(activity["cc"])

    cond do
      @public in to -> :public
      @public in cc -> :unlisted
      true -> :private
    end
  end

  defp list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp list(value) when is_binary(value), do: [value]
  defp list(_value), do: []
end

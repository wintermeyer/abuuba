defmodule Abuuba.Federation.Activity.Featured do
  @moduledoc """
  `Add` and `Remove` on an actor's featured collection: pinned posts and
  featured hashtags.

  Both activities are only honoured for the actor's *own* collection. The
  `target` names a collection, and accepting one that belongs to somebody else
  would let any server pin anything to anybody's profile.

  A pin is also only accepted for a post that actor wrote. Pinning somebody
  else's post to your own profile is not a thing the protocol allows, and
  letting it through would put words on a profile the profile's owner did not
  choose.
  """

  import Ecto.Query

  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag

  @doc false
  def add(activity, opts \\ []), do: apply_change(:add, activity, opts)

  @doc false
  def remove(activity, opts \\ []), do: apply_change(:remove, activity, opts)

  defp apply_change(action, activity, opts) do
    with {:ok, account} <- Helpers.actor(activity, opts),
         :ok <- check_own_collection(activity, account) do
      change(action, activity, account)
    else
      _ -> :ok
    end
  end

  # The collection has to be this actor's own. Otherwise any server could pin
  # anything to anybody's profile.
  defp check_own_collection(activity, account) do
    target = Helpers.uri_of(activity["target"])

    cond do
      is_nil(target) -> {:error, :no_target}
      is_nil(account.uri) -> {:error, :unknown_actor}
      String.starts_with?(target, account.uri) -> :ok
      true -> {:error, :not_their_collection}
    end
  end

  defp change(action, activity, account) do
    uri = Helpers.uri_of(activity["object"])

    case Statuses.get_status_unchecked_by_uri(uri) do
      nil -> featured_tag(action, activity, account)
      status -> pin(action, status, account)
    end
  end

  defp pin(:add, %Status{} = status, account) do
    if status.account_id == account.id do
      now = DateTime.utc_now()

      Repo.insert_all(
        "status_pins",
        [[account_id: account.id, status_id: status.id, inserted_at: now, updated_at: now]],
        on_conflict: :nothing,
        conflict_target: [:account_id, :status_id]
      )
    end

    :ok
  end

  defp pin(:remove, %Status{} = status, account) do
    from(p in "status_pins", where: p.account_id == ^account.id and p.status_id == ^status.id)
    |> Repo.delete_all()

    :ok
  end

  # Not a status, so it may be a hashtag being featured. Anything else is
  # ignored rather than guessed at.
  defp featured_tag(action, activity, account) do
    case tag_name(activity) do
      nil -> :ok
      name -> apply_featured_tag(action, name, account)
    end
  end

  defp tag_name(%{"object" => %{"type" => "Hashtag", "name" => name}}) when is_binary(name),
    do: name

  defp tag_name(_activity), do: nil

  defp apply_featured_tag(:add, name, account) do
    with {:ok, tag} <- Statuses.upsert_tag(name) do
      now = DateTime.utc_now()

      Repo.insert_all(
        "featured_tags",
        [[account_id: account.id, tag_id: tag.id, inserted_at: now, updated_at: now]],
        on_conflict: :nothing,
        conflict_target: [:account_id, :tag_id]
      )

      :ok
    end
  end

  defp apply_featured_tag(:remove, name, account) do
    normalised = Tag.normalise(name)

    from(f in "featured_tags",
      join: t in "tags",
      on: t.id == f.tag_id,
      where: f.account_id == ^account.id and t.name == ^normalised
    )
    |> Repo.delete_all()

    :ok
  end
end

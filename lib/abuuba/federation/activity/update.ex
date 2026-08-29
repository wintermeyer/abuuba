defmodule Abuuba.Federation.Activity.Update do
  @moduledoc """
  A profile or a post changed.

  Which one depends on the object's type, and neither goes through the ordinary
  create path: an `Update` for something we have never seen is not an
  instruction to go and get it, because nobody here asked for it and fetching
  on demand would let any server make us fetch anything.
  """

  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Statuses

  @actor_types ~w(Person Service Application Group Organization)

  @doc false
  def handle(activity, opts \\ []) do
    object = activity["object"]

    cond do
      is_map(object) and object["type"] in @actor_types -> update_actor(object, opts)
      # Only the server that hosts the author may rewrite their post. `Delete`
      # has checked this since it was written; this did not, so any server
      # could have changed anybody's words — and, once attachments federated,
      # taken away their pictures.
      is_map(object) and not Helpers.speaks_for?(activity, object) -> :ok
      is_map(object) -> update_status(object, opts)
      true -> :ok
    end
  end

  defp update_actor(object, opts) do
    case Helpers.uri_of(object) do
      nil ->
        :ok

      uri ->
        # Refetched rather than trusted. The pushed document is a claim; the
        # actor's own endpoint is where the claim gets checked, including the
        # loopback check.
        case refresh_actor(uri, opts) do
          {:ok, _account} -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  defp refresh_actor(uri, opts) do
    case Keyword.get(opts, :refresh_actor) do
      nil -> ResolveActor.refresh(uri, opts)
      refresher -> refresher.(uri)
    end
  end

  defp update_status(object, opts) do
    uri = Helpers.uri_of(object)

    case uri && Statuses.get_status_unchecked_by_uri(uri) do
      nil ->
        # Never seen it. Not an error and not a fetch.
        :ok

      _status ->
        case ResolveStatus.from_document(object, opts) do
          {:ok, _updated} -> :ok
          {:error, :untrustworthy_attribution} -> :ok
          error -> error
        end
    end
  end
end

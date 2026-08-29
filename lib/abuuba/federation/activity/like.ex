defmodule Abuuba.Federation.Activity.Like do
  @moduledoc """
  Somebody favourited a post.

  Only for posts we already hold. A `Like` for something unknown is not worth
  fetching: the post is somebody else's, nobody here follows the author, and
  going to get it would let any server make us fetch anything by pretending to
  like it.
  """

  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Statuses

  @doc false
  def handle(activity, opts \\ []) do
    with {:ok, account} <- Helpers.actor(activity, opts),
         status when not is_nil(status) <-
           Statuses.get_status_unchecked_by_uri(Helpers.uri_of(activity["object"])) do
      case Statuses.favourite(account, status) do
        {:ok, _favourite} -> :ok
        # Already favourited: a redelivery.
        {:error, %Ecto.Changeset{}} -> :ok
        error -> error
      end
    else
      _ -> :ok
    end
  end
end

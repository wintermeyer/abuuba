defmodule Abuuba.Federation.Activity.Block do
  @moduledoc """
  A remote account blocked one of ours.

  Recorded rather than ignored, because it has consequences on our side: the
  follows between the two come down, which is what `Abuuba.Relationships.block/2`
  already does.

  Not shown to the blocked account. Mastodon does not tell somebody they have
  been blocked, and telling them here would make abuuba the server that leaks it.
  """

  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Relationships

  @doc false
  def handle(activity, opts \\ []) do
    with {:ok, blocker} <- Helpers.actor(activity, opts),
         target when not is_nil(target) <-
           Helpers.local_account(Helpers.uri_of(activity["object"])) do
      case Relationships.block(blocker, target) do
        {:ok, _block} -> :ok
        # Already blocked: a redelivery.
        {:error, %Ecto.Changeset{}} -> :ok
        error -> error
      end
    else
      _ -> :ok
    end
  end
end

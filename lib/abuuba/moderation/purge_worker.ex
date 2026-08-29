defmodule Abuuba.Moderation.PurgeWorker do
  @moduledoc """
  Deletes suspended accounts once their grace window has passed.

  A suspension hides everything immediately and sets `purge_after`. Until that
  moment the data is still there, because an appeal upheld after the purge is
  an apology with nothing to give back. After it, keeping the data is only a
  liability.

  Lifting a suspension clears `purge_after`, so an account that was let back in
  is never picked up here. The query asks for both: a row that is still
  suspended and whose window has passed.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    Account
    |> where([a], not is_nil(a.suspended_at) and not is_nil(a.purge_after))
    |> where([a], a.purge_after <= ^now)
    |> limit(100)
    |> Repo.all()
    |> Enum.each(&Accounts.delete_account/1)

    :ok
  end
end

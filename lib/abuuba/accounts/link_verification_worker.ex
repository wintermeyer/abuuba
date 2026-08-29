defmodule Abuuba.Accounts.LinkVerificationWorker do
  @moduledoc """
  Reads the links on a local profile, out of band.

  Never inside the request that saved the profile. Verifying means fetching
  somebody else's web site, and saving a profile would then be as slow as the
  slowest site anybody links to.

  Two shapes of job. Named an account, it checks that one, which is what a
  profile edit queues. Given no arguments, it is the periodic sweep: it finds
  the accounts whose links are due another look and queues one job each, so
  that the work is spread across the queue rather than done in one long job
  that a restart would lose.
  """

  use Oban.Worker,
    queue: :ingress,
    max_attempts: 3,
    # Editing a profile four times in a minute is one check, not four, for as
    # long as a check for that account has not finished — the hourly sweep and
    # a burst of saves collapse into one job.
    #
    # That includes a job already running, which started from the fields as
    # they were then, so an edit made during it would otherwise wait for the
    # weekly sweep. `LinkVerification.verify/2` closes that door from the other
    # side: it notices the row changed under it and asks to be run again.
    unique: [period: :infinity, states: :incomplete]

  alias Abuuba.Accounts
  alias Abuuba.Accounts.LinkVerification

  @snooze_seconds 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    case Accounts.get_account(account_id) do
      nil ->
        # Deleted while queued, which is ordinary.
        :ok

      account ->
        case LinkVerification.verify(account) do
          {:ok, _account} -> :ok
          {:defer, _account} -> {:snooze, @snooze_seconds}
        end
    end
  end

  def perform(%Oban.Job{}) do
    LinkVerification.due() |> Enum.each(&enqueue/1)
  end

  @doc """
  Queues a check for one account, if it has anything to check.
  """
  @spec enqueue(Abuuba.Accounts.Account.t()) :: :ok
  def enqueue(%{domain: nil, fields: fields, id: id}) when fields != [] do
    %{account_id: id} |> new() |> Oban.insert()

    :ok
  end

  def enqueue(_account), do: :ok
end

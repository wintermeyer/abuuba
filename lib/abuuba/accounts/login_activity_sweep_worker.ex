defmodule Abuuba.Accounts.LoginActivitySweepWorker do
  @moduledoc """
  Deletes sign-in records past their day.

  A privacy job. What is in that table is where somebody has been and the
  addresses they were there from, kept to answer "was that me last Tuesday"
  and not to sit in a database for years being the most interesting thing in a
  leak.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Accounts.LoginActivities

  @impl Oban.Worker
  def perform(_job) do
    LoginActivities.sweep()

    :ok
  end
end

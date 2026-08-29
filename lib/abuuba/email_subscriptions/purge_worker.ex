defmodule Abuuba.EmailSubscriptions.PurgeWorker do
  @moduledoc """
  Takes the addresses nobody ever confirmed.

  An address that did not answer within a week did not want the mail, and very
  possibly never asked for it: anybody can type anybody's address into the
  form. Holding on to it would be keeping somebody's address for no reason
  anybody could defend, so this is a privacy job rather than a housekeeping
  one, and it is the reason the docs can say the row goes.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.EmailSubscriptions

  # Long enough that somebody who reads their mail at the weekend still gets to
  # confirm, short enough that an address nobody wanted is not kept for a month.
  @days 7

  @impl Oban.Worker
  def perform(_job) do
    EmailSubscriptions.purge_unconfirmed(@days)

    :ok
  end
end

defmodule Abuuba.Moderation.Signup.UnattendedWorker do
  @moduledoc """
  Closes sign-ups on an open server nobody has been moderating.

  Daily. An open server left unattended fills with spam registrations within
  days, and the admin who forgot about it is the one who finds out. The
  decision is written to the audit log with no actor, so somebody coming back
  to a closed server can see it was the server rather than a colleague.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Moderation.Signup

  @impl Oban.Worker
  def perform(_job) do
    _result = Signup.close_if_unattended()

    :ok
  end
end

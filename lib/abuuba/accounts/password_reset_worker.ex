defmodule Abuuba.Accounts.PasswordResetWorker do
  @moduledoc """
  Looks up the address somebody asked a reset for, and mails them if it is
  theirs.

  ## Why the lookup is here and not in the request

  The request must answer identically whether or not the address has an
  account, and that has to include how long it takes. Doing the lookup in the
  controller and mailing only on one branch gets the words right and the clock
  wrong: one branch runs a `SELECT`, the other runs a `SELECT`, an insert, and
  an SMTP conversation with a third party. That difference is measurable from
  outside — hundreds of milliseconds when the relay is slow — and it answers
  exactly the question the wording refuses to.

  So the controller does one thing, the same thing, for every address: it
  queues this. Both branches cost one insert, and everything that differs
  happens where nobody is holding a stopwatch.

  The address travels in the job's arguments. It is already in the users table
  and the row is pruned with the job, but it is worth knowing it is briefly in
  two places.

  ## Not more than a few an hour

  Per account, and checked here rather than in the request for the same reason
  as the lookup. The request limiter is per client address and does nothing
  about several of them aimed at one mailbox.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Accounts.UserNotifier
  alias Abuuba.RateLimit

  @limit 3
  @window_ms 3_600_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email, "url" => template}}) do
    case Auth.get_user_by_email(email) do
      %User{} = user -> maybe_deliver(user, template)
      nil -> :ok
    end
  end

  defp maybe_deliver(user, template) do
    case RateLimit.hit(key(user), limit: @limit, window_ms: @window_ms) do
      {:ok, _remaining} ->
        {:ok, token} = Auth.create_reset_token(user)

        UserNotifier.deliver_reset_password(user, String.replace(template, ":token", token))

        :ok

      # Somebody is pointing the form at this mailbox. Discarded rather than
      # retried: retrying is the mail this exists to stop.
      {:error, :rate_limited} ->
        :ok
    end
  end

  defp key(%User{id: id}), do: "password_reset:" <> Integer.to_string(id)
end

defmodule AbuubaWeb.PasswordResetController do
  @moduledoc """
  Getting back in without the password.

  ## Both forms post to a controller

  The pages are LiveViews and the submits land here, because a reset ends with
  a session decision — a flash and a redirect — and a LiveView talking over a
  socket has no response to put one on.

  ## The answer is the same either way, including how long it takes

  Asking for a reset says the same thing whether the address belongs to
  somebody here or to nobody. Telling those apart turns this form into a way to
  find out who has an account on this server, which for a social server is a
  list of people worth phishing, and the address is not even needed to ask.

  Matching words are not enough, because a stopwatch answers the same question.
  So this does not look the address up at all: every request queues one job,
  identical in shape and cost, and `Abuuba.Accounts.PasswordResetWorker` decides
  what to do with it out of earshot.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.PasswordResetWorker
  alias Abuuba.Accounts.UserNotifier

  @doc """
  Takes an address and queues a look at whether it belongs to anybody.
  """
  def create(conn, %{"user" => %{"email" => email}}) when is_binary(email) do
    # The URL is built here because only a request knows this server's address,
    # and handed over with a placeholder because only the worker will know the
    # token. Building it there would need the endpoint's host in a job.
    %{email: email, url: url(~p"/reset-password/:token")}
    |> PasswordResetWorker.new()
    |> Oban.insert()

    conn
    |> put_flash(:info, gettext("If that address has an account here, a link is on its way."))
    |> redirect(to: ~p"/login")
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/reset-password")

  @doc """
  Sets the new password, if the link is still good.
  """
  def update(conn, %{"token" => token, "user" => %{} = params}) do
    case Auth.reset_password(token, params) do
      {:ok, user} ->
        # Best effort, and after the write. A mail server that is down must not
        # be the reason somebody cannot get back into their account.
        _ = notify(user)

        conn
        |> put_flash(:info, gettext("Your password is set. You can sign in now."))
        |> redirect(to: ~p"/login")

      # The browser checks the same rule, so this is the request nobody typed.
      # The changeset's own message rather than a fixed one: "too short" is
      # only one of the three ways this fails, and telling somebody who pasted
      # a hundred-character passphrase that it is too short sends them looking
      # for a problem they do not have.
      {:error, changeset} ->
        conn
        |> put_flash(:error, password_error(changeset))
        |> redirect(to: ~p"/reset-password/#{token}")

      :error ->
        expired(conn)
    end
  end

  def update(conn, _params), do: expired(conn)

  defp notify(user) do
    UserNotifier.deliver_password_changed(user)
  rescue
    _error -> :ok
  end

  defp password_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
    |> Map.get(:password, [])
    |> List.first()
    |> case do
      nil -> gettext("That password will not do.")
      message -> gettext("That password will not do: %{reason}", reason: message)
    end
  end

  defp expired(conn) do
    conn
    |> put_flash(:error, gettext("That link has expired or has already been used."))
    |> redirect(to: ~p"/reset-password")
  end
end

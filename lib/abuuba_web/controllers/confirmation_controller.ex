defmodule AbuubaWeb.ConfirmationController do
  @moduledoc """
  Confirming an email address from the link in it.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts.Auth
  alias Abuuba.Settings

  def confirm(conn, %{"token" => token}) do
    case Auth.confirm_user(token) do
      {:ok, user} ->
        conn
        |> put_flash(:info, confirmed_message(user))
        |> redirect(to: ~p"/login")

      :error ->
        # Deliberately not "already confirmed" versus "expired". A confirmation
        # token is guessable-in-principle, so telling the two apart would let
        # somebody probe which addresses are registered here.
        conn
        |> put_flash(
          :error,
          gettext("That confirmation link is not valid any more. Ask for a new one.")
        )
        |> redirect(to: ~p"/login")
    end
  end

  defp confirmed_message(user) do
    if user.approved or Settings.registration_mode() != :approved do
      gettext("Your email address is confirmed. You can sign in now.")
    else
      gettext("Your email address is confirmed. A moderator will look at your registration next.")
    end
  end
end

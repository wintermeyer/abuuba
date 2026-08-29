defmodule AbuubaWeb.API.EmailController do
  @moduledoc """
  `/api/v1/emails`, for the gap between signing up in an app and being able to
  use the account.

  An app that has just made an account holds a token that cannot do anything
  yet: the address is unconfirmed, so every other endpoint answers 403. These
  two are what it can do — ask for the mail again, correct an address that was
  mistyped, and poll for the moment the person follows the link.

  ## Only the app that made the account

  Resending is refused to any other client. An app that did not sign somebody
  up has no business sending them mail, and the address it would send to is one
  it could change on the way. The reference implementation draws the same line
  and answers 403 with the same sentence.

  ## And only while it is still waiting

  Once the address is confirmed there is nothing to resend, and an endpoint
  that kept working would be a way to send somebody mail they did not ask for
  by repeatedly claiming to be signing them up.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Repo
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireScopes, ["write:accounts"] when action in [:create]

  # This one is private without a `RequireUser` above it: the action refuses a
  # request with no user itself, because a client polls it during sign-up while
  # the account is not usable yet. It still says what a token has to carry.
  plug AbuubaWeb.Plugs.RequireScopes, {:any, ["read", "read:accounts"]} when action in [:check]

  @doc """
  Sends the confirmation mail again, to a corrected address if one is given.
  """
  def create(conn, params) do
    with {:ok, user} <- signing_up_user(conn),
         {:ok, user} <- correct_address(user, params["email"]) do
      Auth.deliver_signup_mail(user, &url(~p"/confirm/#{&1}"))

      json(conn, %{})
    else
      {:error, :not_this_application} ->
        API.error(
          conn,
          403,
          "This method is only available to the application the user originally signed-up with"
        )

      {:error, :already_confirmed} ->
        API.error(
          conn,
          403,
          "This method is only available while the e-mail is awaiting confirmation"
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  @doc """
  Whether the address has been confirmed yet.

  A bare `true` or `false` rather than an object, which is what the reference
  implementation sends and therefore what a polling client parses.
  """
  def check(conn, _params) do
    case current_user(conn) do
      %User{confirmed_at: nil} -> json(conn, false)
      %User{} -> json(conn, true)
      _ -> API.error(conn, 401, "The access token is invalid")
    end
  end

  defp signing_up_user(conn) do
    token = conn.assigns[:current_token]
    user = current_user(conn)

    cond do
      is_nil(user) or is_nil(token) -> {:error, :not_this_application}
      user.created_by_application_id != token.application_id -> {:error, :not_this_application}
      not is_nil(user.confirmed_at) -> {:error, :already_confirmed}
      true -> {:ok, user}
    end
  end

  # Absent leaves it alone. A client resending without saying anything about
  # the address is asking for the same mail again, not for a change.
  defp correct_address(user, nil), do: {:ok, user}
  defp correct_address(user, ""), do: {:ok, user}

  defp correct_address(user, email) do
    user |> User.changeset(%{email: email}) |> Repo.update()
  end
end

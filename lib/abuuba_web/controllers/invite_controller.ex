defmodule AbuubaWeb.InviteController do
  @moduledoc """
  `/invite/:invite_code`, the address that goes in the message somebody sends a
  friend.

  Short and memorable, because it is read aloud and typed by hand as often as
  it is clicked. What it does is send the reader to the registration form with
  the code already applied; the form is where signing up happens and there is
  no reason to have two of it.

  ## The same URL answers a client

  A client asking for JSON gets the `Invite` entity, which is what the
  reference implementation does and what lets an app show who is inviting and
  whether the code is still good before it renders a sign-up screen at all.

  ## A code that is no good still gets an answer

  Expired, used up, or never existed: the reader is sent to the form and told
  there, rather than to a 404. Somebody who was invited and mistyped one
  character should land somewhere that explains itself, not on an error page
  that leaves them wondering whether they were invited at all.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Invites
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  def show(conn, %{"invite_code" => code}) do
    invite = Invites.get_by_code(code)

    if json?(conn), do: as_json(conn, invite), else: as_page(conn, code, invite)
  end

  defp as_json(conn, nil), do: API.error(conn, 404, "Record not found")
  defp as_json(conn, invite), do: json(conn, Entities.invite(invite))

  # The code travels in the query string rather than the session, so that the
  # form's own address is shareable and a reload does not lose it.
  defp as_page(conn, _code, nil) do
    conn
    |> put_flash(:error, gettext("That invitation is not one we know."))
    |> redirect(to: ~p"/register")
  end

  defp as_page(conn, code, _invite), do: redirect(conn, to: ~p"/register?invite=#{code}")

  # Content negotiation rather than a separate path, because the reference
  # implementation answers both on this one address and clients follow it.
  defp json?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "json"))
  end
end

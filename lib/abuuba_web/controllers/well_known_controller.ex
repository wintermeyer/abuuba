defmodule AbuubaWeb.WellKnownController do
  @moduledoc """
  The discovery endpoints other servers ask before they ask anything else.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.URIs
  alias Abuuba.Federation.WebFinger

  # Three days. A handle's mapping to an actor URI is effectively permanent, so
  # caching it hard keeps a popular account from turning every mention of it
  # elsewhere into a request here.
  @cache_seconds 3 * 24 * 60 * 60

  @doc """
  Sends a password manager to the page where a password is changed.

  A 302 rather than a page of its own, which is what the convention asks for:
  the manager follows it and offers to generate a new password on whatever
  lands. Signed out, that redirect chain ends at sign-in and comes back here
  afterwards, which is the right answer rather than a dead end.
  """
  def change_password(conn, _params) do
    redirect(conn, to: ~p"/settings/security")
  end

  def webfinger(conn, params) do
    case WebFinger.parse_resource(params["resource"]) do
      {:ok, username, domain} -> respond(conn, username, domain)
      :error -> send_error(conn, :bad_request, gettext("That is not a resource we understand."))
    end
  end

  defp respond(conn, username, domain) do
    cond do
      not URIs.local_domain?(domain) ->
        # We answer only for our own accounts. Answering for another domain
        # would be claiming to speak for it.
        send_error(conn, :not_found, gettext("No such account here."))

      account = Accounts.get_account_by_handle(username, nil) ->
        serve(conn, account)

      true ->
        send_error(conn, :not_found, gettext("No such account here."))
    end
  end

  defp serve(conn, %Account{suspended_at: suspended_at} = account) do
    conn = put_resp_content_type(conn, "application/jrd+json")

    if is_nil(suspended_at) do
      conn
      |> put_resp_header("cache-control", "public, max-age=#{@cache_seconds}")
      |> json(WebFinger.jrd(account))
    else
      # Gone, not missing. A peer that gets a 410 can tombstone the account
      # instead of retrying it forever.
      conn
      |> put_status(:gone)
      |> json(%{error: gettext("That account is gone.")})
    end
  end

  @doc """
  host-meta, which points at the WebFinger endpoint for servers that look here
  first. Still worth serving: some older implementations start here.
  """
  def host_meta(conn, _params) do
    template = "#{URIs.base_url()}/.well-known/webfinger?resource={uri}"

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
      <Link rel="lrdd" template="#{template}"/>
    </XRD>
    """

    conn
    |> put_resp_content_type("application/xrd+xml")
    |> put_resp_header("cache-control", "public, max-age=#{@cache_seconds}")
    |> send_resp(200, xml)
  end

  defp send_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end

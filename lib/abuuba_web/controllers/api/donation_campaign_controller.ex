defmodule AbuubaWeb.API.DonationCampaignController do
  @moduledoc """
  `GET /api/v1/donation_campaigns`, the appeal this server's admin wrote.

  Answers `204` where there is nothing to show, which is the normal case and
  not an error: a client that got a `404` would log it.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Instance.DonationCampaign

  plug AbuubaWeb.Plugs.RequireUser

  # No scope: what comes back is the server's own fundraising banner, the same
  # for everybody signed in and nothing of theirs. The umbrella `read` would
  # have refused every narrowly-scoped token for no gain, since coverage runs
  # from parent to child and never back up.

  def index(conn, _params) do
    case DonationCampaign.current(Gettext.get_locale(AbuubaWeb.Gettext)) do
      nil -> send_resp(conn, 204, "")
      campaign -> json(conn, campaign)
    end
  end
end

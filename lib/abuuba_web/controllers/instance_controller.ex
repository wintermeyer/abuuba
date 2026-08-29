defmodule AbuubaWeb.InstanceController do
  @moduledoc """
  What this server tells crawlers and client apps about itself.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Instance
  alias AbuubaWeb.API.Entities

  # An hour. These change when an admin changes a setting, which is rare, and
  # crawlers ask often enough that an uncached answer is wasted work.
  @cache_seconds 3600

  def well_known_nodeinfo(conn, _params) do
    conn
    |> cache()
    |> json(Instance.well_known_nodeinfo())
  end

  def nodeinfo(conn, _params) do
    conn
    |> cache()
    # The schema asks for this content type specifically, and some crawlers
    # check it before they read the body.
    |> put_resp_content_type("application/json", nil)
    |> put_resp_header(
      "content-type",
      ~s(application/json; profile="http://nodeinfo.diaspora.software/ns/schema/2.0#")
    )
    |> json(Instance.nodeinfo())
  end

  # Shorter than nodeinfo's hour: a client reads `registrations` from here
  # before offering a signup form, so a closed door should be seen closed
  # within minutes.
  @instance_cache_seconds 300

  def show_v2(conn, _params) do
    payload = put_in(Instance.instance_v2(), ["contact", "account"], contact_account())

    conn |> cache_by_language(@instance_cache_seconds) |> json(payload)
  end

  def show_v1(conn, _params) do
    payload = Map.put(Instance.instance_v1(), "contact_account", contact_account())

    conn |> cache_by_language(@instance_cache_seconds) |> json(payload)
  end

  # Rendered here rather than in the context, which builds plain maps and has
  # no business knowing how an account looks on the wire. `Entities.account/1`
  # answers nil for nil, which is what both payloads carry when no account has
  # been named.
  defp contact_account, do: Entities.account(Instance.contact_account())

  defp cache(conn, seconds \\ @cache_seconds) do
    put_resp_header(conn, "cache-control", "public, max-age=#{seconds}")
  end

  # The instance document carries the server rules in the reader's language,
  # so a shared cache that ignored `Accept-Language` would hand one person's
  # translation to everybody for the cache's lifetime.
  defp cache_by_language(conn, seconds) do
    conn
    |> cache(seconds)
    |> put_resp_header("vary", "Authorization, Origin, Accept-Language")
  end
end

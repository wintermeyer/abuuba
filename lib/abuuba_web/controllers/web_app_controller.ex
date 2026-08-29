defmodule AbuubaWeb.WebAppController do
  @moduledoc """
  The three small documents a browser and an admin ask this server for.

  ## The manifest

  What lets somebody add this server to a phone's home screen and have it open
  as an application rather than a tab. Built from the instance settings rather
  than written out, so a server that renames itself does not end up with the
  old name on everybody's home screen.

  ## The stylesheet

  An admin's own CSS, served from this origin and linked from every page. It is
  a text field in the admin area and it goes out exactly as typed: styling a
  server is the one place where "we know better than you what you meant" is
  wrong, and the person who can write here can already change every page.

  Served with its own cache lifetime rather than a long one, because an admin
  editing a colour should see it on the next reload and not on Tuesday.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Settings

  # Short. An admin adjusting a colour reloads to see it, and the file is a few
  # hundred bytes on a page that already fetched a dozen other things.
  @css_max_age 60

  @doc """
  The web app manifest.
  """
  def manifest(conn, _params) do
    title = Settings.get("site_title")

    conn
    |> put_resp_content_type("application/manifest+json")
    |> json(%{
      "id" => "/",
      "name" => title,
      "short_name" => title,
      "description" => to_string(Settings.get("site_description")),
      "start_url" => "/",
      "scope" => "/",
      "display" => "standalone",
      "background_color" => "#ffffff",
      "theme_color" => "#ffffff",
      "icons" => icons(),
      # Where a share from the operating system lands. Without it, "share to"
      # offers this server and then opens the front page, which reads as the
      # share having been lost.
      "share_target" => %{
        "action" => "/share",
        "method" => "GET",
        "params" => %{"title" => "title", "text" => "text", "url" => "url"}
      }
    })
  end

  @doc """
  The admin's own stylesheet.
  """
  def custom_css(conn, _params) do
    css = Settings.get("custom_css") |> to_string()

    conn
    |> put_resp_content_type("text/css")
    |> put_resp_header("cache-control", "public, max-age=#{@css_max_age}")
    |> send_resp(200, css)
  end

  defp icons do
    [
      %{"src" => "/images/icon.svg", "sizes" => "any", "type" => "image/svg+xml"}
    ]
  end
end

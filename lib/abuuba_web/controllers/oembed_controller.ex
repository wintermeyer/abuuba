defmodule AbuubaWeb.OEmbedController do
  @moduledoc """
  The description an editor asks for before it embeds a post.

  Somebody pastes a link into a blog or a chat, the software there fetches this
  with that link, and what comes back tells it what to put in the page. Without
  it the link stays a link.

  ## Only our own posts

  The URL arrives from whoever is asking, so it is checked against this
  server's own address before anything is looked up. Answering for a URL on
  another host would turn this endpoint into a way to make anybody's page
  appear to be embedded from here.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.URIs
  alias Abuuba.Statuses

  # Wide enough for a post with a picture, narrow enough that the frame does
  # not decide the layout of the page it is on.
  @default_width 400
  @default_height 320
  @max_width 1000
  @max_height 2000

  def show(conn, params) do
    case status_for(params["url"]) do
      nil -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
      status -> json(conn, document(status, params))
    end
  end

  # The address has to be one of ours and has to name a post. Anything else is
  # a miss rather than an error: the caller asked whether we can embed this,
  # and the answer is no.
  defp status_for(url) when is_binary(url) do
    with %URI{host: host, path: path} when is_binary(path) <- URI.parse(url),
         true <- host == URIs.local_host(),
         [_, "@" <> _username, id] <- String.split(path, "/"),
         {number, ""} <- Integer.parse(id) do
      Statuses.get_status(number, nil)
    else
      _ -> nil
    end
  end

  defp status_for(_url), do: nil

  defp document(status, params) do
    author = Accounts.get_account(status.account_id)
    width = bounded(params["maxwidth"], @default_width, @max_width)
    height = bounded(params["maxheight"], @default_height, @max_height)

    %{
      "type" => "rich",
      "version" => "1.0",
      "provider_name" => Abuuba.Instance.software_name(),
      "provider_url" => URIs.base_url(),
      "author_name" => display_name(author),
      "author_url" => URIs.profile_url(author),
      "width" => width,
      "height" => height,
      "html" => iframe(status, width, height)
    }
  end

  defp iframe(status, width, height) do
    src = "#{URIs.base_url()}/embed/#{status.id}"

    ~s(<iframe src="#{src}" width="#{width}" height="#{height}" ) <>
      ~s(frameborder="0" scrolling="no" allowfullscreen></iframe>)
  end

  # A number from a stranger, so it is clamped rather than trusted. An
  # unbounded height is a frame that pushes everything off somebody's page.
  defp bounded(nil, fallback, _max), do: fallback

  defp bounded(value, fallback, max) do
    case Integer.parse(to_string(value)) do
      {number, _rest} when number > 0 -> min(number, max)
      _ -> fallback
    end
  end

  defp display_name(%Account{display_name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%Account{username: username}), do: username
  defp display_name(_account), do: ""
end

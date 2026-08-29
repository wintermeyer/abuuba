defmodule AbuubaWeb.InteractionLive do
  @moduledoc """
  "Follow this person" and "reply to this post", for somebody whose account is
  somewhere else.

  ## Why this page exists at all

  A visitor from another server reading a post here cannot act on it here.
  Their account, their session and their following list all live on their own
  server, and the only thing this server can usefully do is hand them back to
  it with the address in hand. Without this page the buttons on a public post
  are decoration for everybody who is not signed in here.

  ## We send them to their server, we do not act for them

  All that happens is a redirect to their own server's search with this
  address in it. Nothing here logs in anywhere, holds a credential or speaks
  for them; that is the whole safety property, and it is why a handle is all
  this page asks for.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Federation.URIs
  alias AbuubaWeb.Meta

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    uri = to_string(params["uri"] || "")

    case socket.assigns[:current_scope] do
      # Already signed in here: the buttons on the page itself do more than
      # this one can, so it gets out of the way.
      %{user: user} when not is_nil(user) ->
        {:ok, push_navigate(socket, to: local_path(uri))}

      _ ->
        {:ok,
         assign(socket,
           page_title: gettext("Take me home"),
           uri: uri,
           error: nil,
           robots: Meta.noindex()
         )}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div class="p-6">
        <h1 class="text-2xl font-semibold">{gettext("Do this from your own server")}</h1>

        <p class="mt-3 text-base-content/80">
          {gettext(
            "Your account lives somewhere else, so following, replying and boosting happen there. Tell us your handle and we will send you home with this address in hand."
          )}
        </p>

        <p :if={@uri != ""} class="mt-2 break-all text-sm text-base-content/60">{@uri}</p>

        <p :if={@error} class="mt-3 text-sm text-error" role="alert">{@error}</p>

        <form id="handoff-form" phx-submit="handoff" class="mt-4 space-y-3">
          <label class="block">
            <span class="label">{gettext("Your handle")}</span>
            <input
              type="text"
              name="handle"
              placeholder="name@server"
              class="input w-full"
            />
          </label>

          <button type="submit" class="btn btn-primary">{gettext("Take me to my server")}</button>
        </form>

        <p class="mt-6 text-sm text-base-content/60">
          {gettext(
            "No password is asked for and nothing is done on your behalf: you are simply sent to your own server's search with this address filled in."
          )}
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("handoff", %{"handle" => handle}, socket) do
    case destination(handle, socket.assigns.uri) do
      {:ok, url} -> {:noreply, redirect(socket, external: url)}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp destination(handle, uri) do
    case handle
         |> to_string()
         |> String.trim()
         |> String.trim_leading("@")
         |> String.split("@") do
      [_name, host] when host != "" ->
        if URIs.local_domain?(host) do
          # Sending them here would be a loop: they are on this page because
          # this server is not theirs.
          {:error,
           gettext(
             "That is this server. Use the buttons on the post itself once you are signed in."
           )}
        else
          {:ok, "https://#{host}/search?q=#{URI.encode_www_form(uri)}"}
        end

      _ ->
        {:error, gettext("A handle looks like name@server.")}
    end
  end

  # Back to the thing they were looking at, as a path on this server.
  defp local_path(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _ -> "/"
    end
  end
end

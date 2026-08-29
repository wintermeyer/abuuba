defmodule AbuubaWeb.ShareLive do
  @moduledoc """
  The page a "share to your fediverse server" button lands on.

  Whatever the other page handed over goes into the compose box: a title, a
  link, some selected text. Nothing is posted until somebody presses send,
  because a link that posts on arrival is a link anybody can put on a page.
  """

  use AbuubaWeb, :live_view

  alias AbuubaWeb.ComposeComponent

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    account = current_account(socket)

    {:ok, assign(socket, page_title: gettext("Share"), account: account, text: text(params))}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, text: text(params))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <p class="border-b border-base-300 p-4 text-sm text-base-content/70">
        {gettext("Something was shared with you. Change it however you like before sending it.")}
      </p>

      <.live_component
        module={ComposeComponent}
        id="compose"
        account={@account}
        user={@current_scope.user}
        shared_text={@text}
      />
    </Layouts.app>
    """
  end

  # Title, then the words, then the link, each only if it is there. The order
  # is what somebody would have typed, and joining with blank pieces would put
  # stray newlines in the box.
  defp text(params) do
    [params["title"], params["text"], params["url"]]
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end
end

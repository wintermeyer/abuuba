defmodule AbuubaWeb.LandingLive do
  @moduledoc """
  What somebody sees before they have an account here.

  ## It shows the place rather than describing it

  A landing page that only explains the software tells a visitor nothing about
  whether they want to be here. Recent public posts do: who is around, what
  they talk about, whether anybody is around at all. So the page carries both,
  and the posts are the larger half.

  ## Signed in, it gets out of the way

  Somebody with a home timeline has no use for the sales pitch, so they are
  sent to it. The alternative is a front page that is useful exactly once.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Instance
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.RegistrationWords

  @page_size 10

  # Nobody is signed in on this page, so a server that keeps its timelines for
  # people with an account shows no preview at all here.
  defp preview do
    if Settings.public_timelines_readable?(nil) do
      Entities.statuses(Statuses.public_timeline(local: true, limit: @page_size), nil)
    else
      []
    end
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    case socket.assigns[:current_scope] do
      %{user: user} when not is_nil(user) ->
        {:ok, push_navigate(socket, to: ~p"/home")}

      _ ->
        {:ok,
         assign(socket,
           page_title: Settings.get("site_title") || Instance.software_name(),
           posts: preview(),
           registration_mode: Settings.registration_mode()
         )}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <section class="border-b border-base-300 p-6">
        <h1 class="text-3xl font-semibold">{@page_title}</h1>

        <p class="mt-3 text-base-content/80">
          {gettext(
            "This is a server on the fediverse: a network of independent servers whose people can follow and talk to each other, whichever one they are on. An account here can follow anybody anywhere on it."
          )}
        </p>

        <p class="mt-3 text-base-content/80">
          {gettext("It runs %{software}, which is free software anybody may run.",
            software: Instance.software_name()
          )}
        </p>

        <p class="mt-3 text-sm text-base-content/70">
          {RegistrationWords.note(@registration_mode)}
        </p>

        <div class="mt-4 flex flex-wrap gap-2">
          <a :if={@registration_mode != :closed} href={~p"/register"} class="btn btn-primary">
            {gettext("Create an account")}
          </a>
          <a href={~p"/login"} class="btn">{gettext("Log in")}</a>
          <a href={~p"/explore"} class="btn btn-ghost">{gettext("Look around first")}</a>
        </div>
      </section>

      <h2 class="px-6 pt-4 text-xs uppercase text-base-content/60">
        {gettext("Recently, from people here")}
      </h2>

      <.status
        :for={post <- @posts}
        id={"landing-#{post["id"]}"}
        status={post}
        interactive={false}
      />

      <p :if={@posts == []} class="p-8 text-center text-base-content/60">
        {gettext("Nobody has posted publicly here yet.")}
      </p>
    </Layouts.app>
    """
  end
end

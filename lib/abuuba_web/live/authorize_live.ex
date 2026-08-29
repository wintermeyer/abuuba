defmodule AbuubaWeb.AuthorizeLive do
  @moduledoc """
  The consent screen.

  It names the app and lists, in plain words, what the app will be able to do.
  A list of scope strings is not consent: nobody can weigh `write:statuses`
  against `read:notifications` unless somebody translates them first, and a
  consent screen that is not understood is a formality rather than a decision.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.OAuth
  alias Abuuba.OAuth.Application
  alias Abuuba.OAuth.Scopes
  alias AbuubaWeb.ScopeWords

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    application = OAuth.get_application_by_client_id(params["client_id"])
    redirect_uri = params["redirect_uri"]

    cond do
      is_nil(application) ->
        {:ok, assign(socket, :error, gettext("That application is not registered here."))}

      not Application.registered_redirect_uri?(application, redirect_uri || "") ->
        # Never redirect to an unregistered URI, not even to report the error:
        # doing so is the open redirect that lets an authorization code be
        # stolen in the first place.
        {:ok,
         assign(
           socket,
           :error,
           gettext("That redirect address is not registered for this application.")
         )}

      params["response_type"] != "code" ->
        {:ok, assign(socket, :error, gettext("Only the authorization code flow is supported."))}

      true ->
        mount_request(socket, application, params)
    end
  end

  defp mount_request(socket, application, params) do
    case Scopes.parse(params["scope"]) do
      {:ok, requested} ->
        granted = Scopes.narrow(requested, application.scopes)

        {:ok,
         socket
         |> assign(:error, nil)
         |> assign(:page_title, gettext("Authorize %{app}", app: application.name))
         |> assign(:application, application)
         |> assign(:scopes, granted)
         |> assign(:params, params)}

      {:error, unknown} ->
        {:ok,
         assign(
           socket,
           :error,
           gettext("This application asked for permissions this server does not know: %{scopes}",
             scopes: Enum.join(unknown, ", ")
           )
         )}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md px-4 py-10">
        <div :if={@error} class="rounded-lg border border-red-400 p-4">
          <h1 class="font-semibold">{gettext("Something is wrong with this request")}</h1>
          <p class="mt-2 text-zinc-600 dark:text-zinc-400">{@error}</p>
        </div>

        <div :if={is_nil(@error)}>
          <h1 class="text-xl font-semibold">
            {gettext("Give %{app} access to your account?", app: @application.name)}
          </h1>

          <p class="mt-2 text-zinc-600 dark:text-zinc-400">
            {gettext("Signed in as %{handle}.", handle: @current_scope.user.email)}
          </p>

          <h2 class="mt-6 font-medium">{gettext("It will be able to:")}</h2>
          <ul class="mt-2 space-y-1 text-zinc-700 dark:text-zinc-300">
            <li :for={scope <- @scopes}>{ScopeWords.describe(scope)}</li>
          </ul>

          <form method="post" action={~p"/oauth/authorize"} class="mt-6 space-y-3">
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <input type="hidden" name="client_id" value={@params["client_id"]} />
            <input type="hidden" name="redirect_uri" value={@params["redirect_uri"]} />
            <input type="hidden" name="scope" value={Scopes.to_string(@scopes)} />
            <input type="hidden" name="state" value={@params["state"]} />
            <input type="hidden" name="code_challenge" value={@params["code_challenge"]} />
            <input
              type="hidden"
              name="code_challenge_method"
              value={@params["code_challenge_method"]}
            />

            <button
              type="submit"
              name="approve"
              value="true"
              class="w-full rounded-lg bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
            >
              {gettext("Allow")}
            </button>

            <button
              type="submit"
              name="approve"
              value="false"
              class="w-full rounded-lg border px-4 py-2 font-medium"
            >
              {gettext("Cancel")}
            </button>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

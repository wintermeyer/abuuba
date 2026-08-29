defmodule AbuubaWeb.LanguagePicker do
  @moduledoc """
  The language picker, for settings and for the logged-out pages alike.

  Each language is named in itself, never translated. Somebody looking for a
  language they can read cannot find "German" if the page is currently in a
  language they do not understand, and "Deutsch" is legible from any starting
  point.

  A form rather than links, because switching language changes state on the
  server and a GET that does so is one prefetch away from being changed for
  you.
  """

  use Phoenix.Component
  use Gettext, backend: AbuubaWeb.Gettext
  use AbuubaWeb, :verified_routes

  alias Abuuba.I18n

  # Endonyms: each language's name for itself.
  @names %{"en" => "English", "de" => "Deutsch"}

  attr :current, :string, required: true, doc: "the locale in force"
  attr :return_to, :string, default: "/", doc: "where to send the reader back to"
  attr :class, :string, default: nil

  def language_picker(assigns) do
    assigns = assign(assigns, :locales, I18n.known_locales())

    ~H"""
    <form method="post" action={~p"/locale"} class={@class}>
      <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
      <input type="hidden" name="return_to" value={@return_to} />

      <label for="locale-picker" class="block text-sm font-medium">
        {gettext("Language")}
      </label>

      <div class="mt-1 flex gap-2">
        <select
          id="locale-picker"
          name="locale"
          class="rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
        >
          <option :for={locale <- @locales} value={locale} selected={locale == @current}>
            {name(locale)}
          </option>
        </select>

        <button
          type="submit"
          class="rounded-lg bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
        >
          {gettext("Change")}
        </button>
      </div>
    </form>
    """
  end

  @doc """
  A language's name in itself.
  """
  @spec name(String.t()) :: String.t()
  def name(locale), do: Map.get(@names, locale, locale)
end

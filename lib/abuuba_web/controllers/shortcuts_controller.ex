defmodule AbuubaWeb.ShortcutsController do
  @moduledoc """
  The page listing every keyboard shortcut.

  A page rather than a modal, so that it can be linked to, read by somebody who
  cannot open a modal, printed, and found by search. A shortcut nobody can
  discover is a shortcut nobody uses, which is most of them in most software.
  """

  use AbuubaWeb, :controller

  alias AbuubaWeb.Hotkeys

  def show(conn, _params) do
    render(conn, :show, shortcuts: Hotkeys.all(), page_title: gettext("Keyboard shortcuts"))
  end
end

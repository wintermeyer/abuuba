defmodule AbuubaWeb.Plugs.Accessibility do
  @moduledoc """
  Puts somebody's accessibility preferences where the layout can read them.

  In the layout's assigns rather than fetched by each page, because these have
  to be on the `<html>` element before anything renders: a page that applied
  reduced motion after its own animation started has already moved.
  """

  import Plug.Conn

  alias Abuuba.Accounts.Preferences

  @behaviour Plug
  import AbuubaWeb.Scope

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    assign(conn, :accessibility, Preferences.for_user(current_user(conn)))
  end
end

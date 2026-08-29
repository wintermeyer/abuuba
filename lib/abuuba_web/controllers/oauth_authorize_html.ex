defmodule AbuubaWeb.OAuthAuthorizeHTML do
  @moduledoc """
  The page shown to a client with no callback of its own: the code, to copy.
  """

  use AbuubaWeb, :html

  def show_code(assigns) do
    ~H"""
    <main class="mx-auto max-w-md px-4 py-10">
      <h1 class="text-xl font-semibold">{gettext("Copy this code into the app")}</h1>
      <code class="mt-4 block break-all rounded-lg border p-4 font-mono">{@code}</code>
    </main>
    """
  end
end

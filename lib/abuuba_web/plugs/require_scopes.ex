defmodule AbuubaWeb.Plugs.RequireScopes do
  @moduledoc """
  Refuses a request whose token does not carry the scopes an endpoint needs.

      plug AbuubaWeb.Plugs.RequireScopes, ["read:statuses"]

  Declared per endpoint rather than inferred, because the alternative is an
  endpoint that quietly accepts any token because nobody remembered to say
  what it needed.

  A list means all of them. Where the reference implementation accepts any one
  of several — an umbrella scope or the narrow child that implies the same
  access — declare that:

      plug AbuubaWeb.Plugs.RequireScopes, {:any, ["admin:read", "admin:read:accounts"]}

  Without this, advertising a scope like `admin:read:accounts` and then never
  naming it leaves an app that asked for exactly the right narrow thing refused
  everywhere, since coverage runs from parent to child and never back up.

  A handful of endpoints answer a stranger with no token at all, and search is
  the one that matters. Those are declared with the token as a condition:

      plug AbuubaWeb.Plugs.RequireScopes, {:when_authenticated, ["read:search"]}

  which enforces the scope on every request that brings a token and leaves the
  anonymous case exactly as it was. Requiring the scope outright there would
  refuse the app while still answering the stranger, which is the wrong way
  round.
  """

  use Gettext, backend: AbuubaWeb.Gettext

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias Abuuba.OAuth.AccessToken
  alias Abuuba.OAuth.Scopes

  @behaviour Plug

  @impl Plug
  def init({mode, required} = opts)
      when mode in [:when_authenticated, :any] and is_list(required),
      do: opts

  def init(required) when is_list(required), do: required

  @impl Plug
  def call(conn, {:when_authenticated, required}) do
    case conn.assigns[:current_token] do
      %AccessToken{} -> call(conn, required)
      _ -> conn
    end
  end

  def call(conn, {:any, required}) do
    enforce(conn, required, fn held -> Enum.any?(required, &Scopes.covers?(held, &1)) end)
  end

  def call(conn, required) do
    enforce(conn, required, &Scopes.covers_all?(&1, required))
  end

  defp enforce(conn, required, held?) do
    case conn.assigns[:current_token] do
      %AccessToken{scopes: held} ->
        if held?.(held), do: conn, else: forbid(conn, required)

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: gettext("The access token is invalid.")})
        |> halt()
    end
  end

  defp forbid(conn, required) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: gettext("This action is outside the authorized scopes."),
      # Naming what was needed turns a dead end into something a developer can
      # act on, and the scope names are not secret.
      required_scopes: required
    })
    |> halt()
  end
end

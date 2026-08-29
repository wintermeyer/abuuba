defmodule AbuubaWeb.DevMailboxTest do
  @moduledoc """
  The way to the development mailbox, and the promise that it is not a way to
  anything in production.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Abuuba.RateLimit
  alias Abuuba.Settings

  setup do
    RateLimit.reset()
    Settings.put_registration_mode(:open)
    on_exit(fn -> Application.delete_env(:abuuba, :dev_routes) end)

    :ok
  end

  defp with_dev_routes(value, fun) do
    Application.put_env(:abuuba, :dev_routes, value)

    fun.()
  end

  describe "in development" do
    test "every page carries a way to the mailbox", %{conn: conn} do
      with_dev_routes(true, fn ->
        html = conn |> get(~p"/") |> html_response(200)

        assert html =~ "/dev/mailbox"
      end)
    end

    test "the screen that just sent one says where it went", %{conn: conn} do
      with_dev_routes(true, fn ->
        {:ok, view, _html} = live(conn, ~p"/register")

        html =
          view
          |> form("form",
            user: %{
              username: "mailbox_reader",
              email: "mailbox_reader@example.com",
              password: "correct horse battery"
            }
          )
          |> render_submit()

        # The moment you want the mailbox is the moment you have just been told
        # to check your email.
        assert html =~ "Check your email"
        assert html =~ "Open the mailbox"
      end)
    end
  end

  describe "anywhere else" do
    test "there is no link, because there is nothing to link to", %{conn: conn} do
      with_dev_routes(false, fn ->
        html = conn |> get(~p"/") |> html_response(200)

        # The route is only mounted where the flag is set, so a link without it
        # is a 404 with this server's name on it.
        refute html =~ "/dev/mailbox"
      end)
    end

    test "nor a sentence about one", %{conn: conn} do
      with_dev_routes(false, fn ->
        {:ok, view, _html} = live(conn, ~p"/register")

        html =
          view
          |> form("form",
            user: %{
              username: "somebody_else",
              email: "somebody_else@example.com",
              password: "correct horse battery"
            }
          )
          |> render_submit()

        assert html =~ "Check your email"
        refute html =~ "Open the mailbox"
      end)
    end
  end
end

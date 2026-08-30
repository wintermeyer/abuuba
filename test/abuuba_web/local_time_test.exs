defmodule AbuubaWeb.LocalTimeTest do
  @moduledoc """
  An absolute time, shown to somebody who is not in UTC.

  `Formats.datetime/2` renders the instant in UTC and said so nowhere, so
  "Signed in — Aug 30, 2026, 10:12 AM" was two hours off for the person in
  Berlin reading it, with nothing on the page to suggest it. On a screen whose
  whole purpose is "was that me last Tuesday", an hour in the wrong direction
  is the difference between recognising yourself and not.

  The fix is split between the two halves that each know something the other
  does not. The server knows the instant, and writes it into the `datetime`
  attribute where it cannot be misread; the browser knows the reader's zone and
  its daylight-saving history, which is a database this server does not carry
  and does not want to. With no script the reader sees the true instant marked
  UTC, which is inconvenient and not wrong; the alternative it replaces was
  convenient and wrong.
  """
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.LoginActivities
  alias AbuubaWeb.Formats

  describe "the formatter" do
    test "says which zone it is in when asked" do
      at = ~U[2026-08-30 10:12:31Z]

      assert Formats.datetime(at, zone: true) =~ "UTC"
      refute Formats.datetime(at) =~ "UTC"
    end

    test "and the machine-readable form is the instant itself" do
      assert Formats.iso(~U[2026-08-30 10:12:31Z]) == "2026-08-30T10:12:31Z"
    end

    test "reading a timestamp Ecto handed back without a zone" do
      # The audit log and the report notes arrive through schemaless queries,
      # which is a NaiveDateTime. They are stored UTC, so saying so is right.
      assert Formats.iso(~N[2026-08-30 10:12:31]) == "2026-08-30T10:12:31Z"
    end
  end

  describe "a page that shows one" do
    setup %{conn: conn} do
      account = account_fixture(%{username: "reader"})

      user =
        user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))

      %{conn: conn, user: user}
    end

    test "hands the browser the instant, not the rendering", %{conn: conn, user: user} do
      LoginActivities.record(user, success: true, ip: "127.0.0.1")

      {:ok, _live, html} = live(conn, ~p"/settings/security")

      assert html =~ ~s(<time)
      assert html =~ ~s(data-local)
      # An ISO instant with its zone on it, which is what `Date` in a browser
      # parses without guessing.
      assert html =~ ~r/datetime="\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"/
    end

    test "and says UTC in the text, for a reader with no script", %{conn: conn, user: user} do
      LoginActivities.record(user, success: true, ip: "127.0.0.1")

      {:ok, _live, html} = live(conn, ~p"/settings/security")

      assert html =~ "UTC"
    end
  end

  describe "the compose box, which was already right" do
    test "shows a scheduled time back in the zone it was typed in, with no UTC on it" do
      # It takes the browser's offset over the wire and subtracts it before
      # rendering, so what it shows is already local. Labelling that UTC would
      # be the same bug pointing the other way.
      source = File.read!("lib/abuuba_web/live/compose_component.ex")

      assert source =~ "DateTime.add(-offset, :minute) |> Formats.datetime()"
      refute source =~ "DateTime.add(-offset, :minute) |> Formats.datetime(zone: true)"
    end
  end
end

defmodule AbuubaWeb.PageHelperTest do
  @moduledoc """
  The helper that makes a short `refute` against a page safe.

  A rendered page carries a fresh `csrf-token`, a `data-phx-session` and a
  `data-phx-static` on every request, all base64. A three-character refute
  against that matches by chance about once in 641 renders -- measured, and the
  cause of #245, which failed twice in a year and could never be reproduced.

  `page/1` takes those out. It has a test of its own because a helper that
  quietly stopped stripping would put the flake back without anything going
  red, and because the assertion it protects only fails one run in six hundred.
  """
  use AbuubaWeb.ConnCase, async: true

  describe "page/1" do
    test "takes out the blobs that change on every request", %{conn: conn} do
      html = conn |> get(~p"/about") |> html_response(200)

      assert html =~ "csrf-token"
      assert html =~ "data-phx-session"

      stripped = page(html)

      refute stripped =~ "data-phx-session=\""
      refute stripped =~ "data-phx-static=\""
      refute stripped =~ "csrf-token\" content=\""
    end

    test "and leaves everything a person can read", %{conn: conn} do
      html = conn |> get(~p"/about") |> html_response(200)

      # The point of the helper is that an assertion about the page reads the
      # same afterwards. Two renders of the same page differ only in the parts
      # it removes.
      other = build_conn() |> get(~p"/about") |> html_response(200)

      assert page(html) == page(other)
      refute html == other
    end
  end
end

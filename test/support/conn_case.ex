defmodule AbuubaWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AbuubaWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AbuubaWeb.Endpoint

      use AbuubaWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AbuubaWeb.ConnCase
    end
  end

  setup tags do
    # Clears the sandbox and the tables that outlive a test: the rate limit
    # buckets, whose counters would otherwise make every later test on the same
    # address answer 429, and the delivery circuit breaker.
    Abuuba.DataCase.setup_sandbox(tags)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  A rendered page with the machine-generated blobs taken out.

  For `refute page(html) =~ "..."` against anything short. A rendered page
  carries a fresh `csrf-token`, a `data-phx-session` and a `data-phx-static`,
  all base64 and all different on every request -- about 166 bytes of a page
  change between two renders of the same URL. A three-character refute against
  that hits a random match roughly **once in 641 renders**, measured, which is
  a red suite a couple of times a year for a reason that has nothing to do with
  the code.

  Four characters is 64 times safer and five is 4,000 times, so only the short
  ones have ever gone off; this makes the length stop mattering. Everything a
  person can read is still here, so an assertion about the page reads the same.
  """
  @spec page(String.t()) :: String.t()
  def page(html) do
    html
    |> String.replace(~r/<meta name="csrf-token" content="[^"]*">/, "")
    |> String.replace(~r/ (data-phx-session|data-phx-static)="[^"]*"/, "")
    # The root element's id is generated per render too, and is the one an
    # equality check between two renders finds last.
    |> String.replace(~r/ id="phx-[A-Za-z0-9_-]+"/, "")
  end

  @doc """
  Puts the headers from `Abuuba.Federation.Signature.sign/1` on a test conn.

  Plug refuses `host` as an ordinary request header in a test conn, so it goes
  on the struct instead. It still has to match what was signed, since `host` is
  one of the signed headers.
  """
  def apply_signed_headers(conn, headers) do
    Enum.reduce(headers, conn, fn
      {"host", value}, acc -> %{acc | host: value}
      {name, value}, acc -> Plug.Conn.put_req_header(acc, name, value)
    end)
  end
end

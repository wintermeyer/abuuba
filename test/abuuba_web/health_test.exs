defmodule AbuubaWeb.HealthTest.NoDatabase do
  @moduledoc false
  # A repo whose connection is refused, which is what a database that is not
  # there looks like from inside the check.
  def query(_sql, _params, _opts), do: {:error, %DBConnection.ConnectionError{message: "down"}}
end

defmodule AbuubaWeb.HealthTest.NotStarted do
  @moduledoc false
  # And one that is not running at all, which raises rather than answering.
  def query(_sql, _params, _opts), do: exit({:noproc, {GenServer, :call, []}})
end

defmodule AbuubaWeb.HealthTest do
  use AbuubaWeb.ConnCase, async: true

  describe "the liveness check" do
    test "answers without asking anything else", %{conn: conn} do
      # What a supervisor reads before deciding to restart the process. A check
      # that can fail for an unrelated reason would have it restarting a
      # healthy server.
      conn = get(conn, "/health")

      assert response(conn, 200) == "ok"
    end

    test "and needs nobody to be signed in", %{conn: conn} do
      assert conn |> get("/health") |> Map.get(:status) == 200
    end

    test "and says nothing about what is installed here", %{conn: conn} do
      # A health endpoint that lists versions is a reconnaissance endpoint that
      # also happens to report health.
      body = conn |> get("/health") |> response(200)

      refute body =~ "abuuba"
      refute body =~ Abuuba.Instance.version()
    end
  end

  test "and says what it is answering with", %{conn: conn} do
    # A response with no content type is one some proxies decide is a
    # download. Two bytes, but they have to be labelled.
    conn = get(conn, "/health")

    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/plain"
  end

  describe "the readiness check" do
    test "asks the database, and says yes when it answers", %{conn: conn} do
      conn = get(conn, "/health/ready")

      assert response(conn, 200) == "ok"
    end

    test "and says no when the database is not there" do
      # The distinction the whole endpoint exists for: a rolling deploy that
      # cannot tell these apart sends every request to a server whose database
      # is not up yet.
      #
      # Asked of the check rather than through the endpoint, because taking the
      # real database away mid-suite would take every other test with it.
      refute Abuuba.Health.ready?(AbuubaWeb.HealthTest.NoDatabase)
    end

    test "and says no rather than crashing when the repo is not even running" do
      refute Abuuba.Health.ready?(AbuubaWeb.HealthTest.NotStarted)
    end
  end
end

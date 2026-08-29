defmodule Abuuba.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Abuuba.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Abuuba.Federation.HTTP.CircuitBreaker
  alias Abuuba.RateLimit
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Abuuba.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Abuuba.DataCase
    end
  end

  setup tags do
    Abuuba.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Abuuba.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    reset_shared_tables()
  end

  # The sandbox rolls back rows and cannot touch ETS, so a named table that
  # outlives a test carries one test's state into the next. Both of these are
  # keyed by host or address, and every federation test in the suite uses
  # `remote.example`, so the sharing is total.
  #
  # The circuit breaker is the one that hurt: five failed deliveries anywhere
  # in the run opened it, and every later test that expected a fetch to
  # succeed got `{:error, :circuit_open}` instead. Which tests those were
  # depended on the seed, so it read as flakiness in whichever file happened
  # to run after the failures -- and every one of them passed when run alone.
  defp reset_shared_tables do
    RateLimit.reset()
    CircuitBreaker.reset()
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

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
  Environment variables for one test, put back afterwards. A `nil` unsets one.

      with_env(%{"MASTODON_DATABASE_URL" => url, "MASTODON_S3_BUCKET" => nil})

  Only in an `async: false` case. The environment is one global map shared by
  every test process, so a concurrent test reads whatever this one has just
  put there.
  """
  def with_env(vars) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    put_env(vars)
    on_exit(fn -> put_env(previous) end)
  end

  defp put_env(vars) do
    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  @doc """
  The import steps registered for one test, put back afterwards.

  They are application configuration, so this has the same `async: false`
  requirement `with_env/1` does.
  """
  def with_steps(steps) do
    previous = Application.get_env(:abuuba, :import_steps)

    Application.put_env(:abuuba, :import_steps, steps)
    on_exit(fn -> Application.put_env(:abuuba, :import_steps, previous) end)
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

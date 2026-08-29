defmodule Abuuba.Imports.Worker do
  @moduledoc """
  Reads one uploaded file into an account, in the background.

  Minutes of work for somebody with years of posts or twenty thousand follows,
  so it cannot happen inside a request. The row it updates is what the settings
  page watches, which is also what makes closing the tab harmless.

  ## Tried once

  Not because failing is fine, but because a retry would start again from the
  first row and redo everything up to the failure. An import that stops halfway
  leaves a row saying where it stopped and what went wrong, and somebody can
  upload the file again — which is the same work, decided by a person who can
  see what happened.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 1

  alias Abuuba.Imports

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_id" => id}}) do
    case Imports.get(id) do
      nil -> :ok
      run -> execute(run)
    end
  end

  defp execute(run) do
    {:ok, _finished} = Imports.run(run)

    :ok
  end

  @doc """
  Queues the reading of one upload.
  """
  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%{id: id}) do
    %{import_id: id} |> new() |> Oban.insert()
  end
end

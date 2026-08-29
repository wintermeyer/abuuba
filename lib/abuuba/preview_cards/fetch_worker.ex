defmodule Abuuba.PreviewCards.FetchWorker do
  @moduledoc """
  Fetches the card for a post's first link, after the post has been made.

  Never inside the request. Unfurling means talking to a server that may be
  slow, down, or deliberately taking its time, and posting would then be as
  slow as the slowest site anybody links to.

  A link that cannot be read is not an error worth retrying forever: plenty of
  pages are behind a login, or gone, or answer only to a browser. The post is
  fine without a card.
  """

  use Oban.Worker, queue: :ingress, max_attempts: 3

  alias Abuuba.PreviewCards
  alias Abuuba.Statuses

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"status_id" => status_id, "url" => url}}) do
    case Statuses.get_status_unchecked(status_id) do
      nil ->
        # Deleted while queued, which is ordinary.
        :ok

      status ->
        case PreviewCards.fetch(url) do
          {:ok, card} -> PreviewCards.attach(status, card)
          {:error, _reason} -> :ok
        end
    end
  end

  @doc """
  Queues the work for a post, if it carries a link at all.
  """
  @spec enqueue(Abuuba.Statuses.Status.t()) :: :ok
  def enqueue(status) do
    case PreviewCards.first_url(status.text) do
      nil ->
        :ok

      url ->
        %{status_id: status.id, url: url} |> new() |> Oban.insert()

        :ok
    end
  end
end

defmodule Abuuba.Federation.Handlers do
  @moduledoc """
  Where an activity turns into a change.

  The handlers themselves arrive with their own issues; this is the dispatch
  point and the contract they have to meet.

  **Every handler is idempotent.** Both the network and the queue deliver at
  least once, so the same activity arriving twice is ordinary rather than a
  fault. Running one twice has to be the same as running it once.

  **Every handler tolerates arriving out of order.** An `Update` before a
  `Create`, or a `Delete` for something we never had, are ordinary too:
  activities travel over separate connections and one can overtake another.
  Neither may raise, and neither may leave a half-built row.

  An activity of a type nothing here handles is `:ok` rather than an error.
  Returning an error would make the queue retry something no version of this
  software is ever going to do.
  """

  require Logger

  alias Abuuba.Federation.Activity

  @doc """
  Dispatches an activity to whatever handles it.
  """
  @spec handle(map(), keyword()) :: :ok | {:error, term()}
  def handle(activity, opts \\ [])

  def handle(%{"type" => type} = activity, opts), do: dispatch(type, activity, opts)

  def handle(_activity, _opts), do: :ok

  defp dispatch("Create", activity, opts), do: Activity.Create.handle(activity, opts)
  defp dispatch("Announce", activity, opts), do: Activity.Announce.handle(activity, opts)
  defp dispatch("Delete", activity, opts), do: Activity.Delete.handle(activity, opts)
  defp dispatch("Follow", activity, opts), do: Activity.Follow.handle(activity, opts)
  # An Accept or Reject means one thing wrapping a Follow and quite another
  # wrapping a QuoteRequest, so what it wraps decides where it goes.
  defp dispatch("Accept", %{"object" => %{"type" => "QuoteRequest"}} = activity, opts),
    do: Activity.QuoteRequest.accepted(activity, opts)

  defp dispatch("Accept", activity, opts), do: Activity.Accept.handle(activity, opts)

  defp dispatch("Reject", %{"object" => %{"type" => "QuoteRequest"}} = activity, opts),
    do: Activity.QuoteRequest.rejected(activity, opts)

  defp dispatch("Reject", activity, opts), do: Activity.Reject.handle(activity, opts)
  defp dispatch("Undo", activity, opts), do: Activity.Undo.handle(activity, opts)
  defp dispatch("Like", activity, opts), do: Activity.Like.handle(activity, opts)
  defp dispatch("Block", activity, opts), do: Activity.Block.handle(activity, opts)
  defp dispatch("Update", activity, opts), do: Activity.Update.handle(activity, opts)
  defp dispatch("Flag", activity, opts), do: Activity.Flag.handle(activity, opts)
  defp dispatch("Add", activity, opts), do: Activity.Featured.add(activity, opts)
  defp dispatch("Remove", activity, opts), do: Activity.Featured.remove(activity, opts)
  defp dispatch("Move", activity, opts), do: Activity.Move.handle(activity, opts)
  defp dispatch("QuoteRequest", activity, opts), do: Activity.QuoteRequest.handle(activity, opts)

  # An activity nothing here acts on is done rather than failed: returning an
  # error would make the queue retry something no version of this software is
  # going to do.
  defp dispatch(type, _activity, _opts) do
    Logger.debug("ignoring #{type} activity, which nothing here handles yet")

    :ok
  end
end

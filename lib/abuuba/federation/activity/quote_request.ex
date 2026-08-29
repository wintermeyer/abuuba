defmodule Abuuba.Federation.Activity.QuoteRequest do
  @moduledoc """
  Somebody asked permission to quote one of our posts, or granted us permission
  to quote one of theirs.

  The asking half is answered by policy rather than by a prompt. A quote
  request that sat waiting for its author to notice would mean quotes silently
  never working, and the person quoting would have no idea why; a policy at
  least gives an answer.

  The granting half carries the approval URI, which is the evidence a quote was
  consented to. Without storing it there is nothing to show a reader and nothing
  for another server to check.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Activity.Helpers
  alias Abuuba.Federation.Delivery
  alias Abuuba.Federation.Quotes
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Federation.Serializer
  alias Abuuba.Repo
  alias Abuuba.Statuses

  @doc false
  def handle(activity, opts \\ []) do
    with {:ok, requester} <- Helpers.actor(activity, opts),
         status when not is_nil(status) <- quoted_status(activity) do
      answer(status, requester, activity, opts)
    else
      _ -> :ok
    end
  end

  @doc """
  Records the approval carried by an `Accept` of a quote request of ours.
  """
  @spec accepted(map(), keyword()) :: :ok
  def accepted(activity, _opts \\ []) do
    with quoting_uri when is_binary(quoting_uri) <- quoting_uri(activity),
         status when not is_nil(status) <- Statuses.get_status_unchecked_by_uri(quoting_uri),
         approval when is_binary(approval) <- approval_uri(activity) do
      from(q in "quotes", where: q.status_id == ^status.id)
      |> Repo.update_all(set: [approval_uri: approval, updated_at: DateTime.utc_now()])

      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Marks a quote of ours revoked, which is what a `Reject` after an `Accept`
  means.
  """
  @spec rejected(map(), keyword()) :: :ok
  def rejected(activity, _opts \\ []) do
    with quoting_uri when is_binary(quoting_uri) <- quoting_uri(activity),
         status when not is_nil(status) <- Statuses.get_status_unchecked_by_uri(quoting_uri) do
      Quotes.revoke(status.id)
    else
      _ -> :ok
    end
  end

  # Only our own posts can be quoted with our permission.
  defp quoted_status(activity) do
    uri = Helpers.uri_of(activity["object"])

    case uri && Statuses.get_status_unchecked_by_uri(uri) do
      nil -> nil
      status -> if status.local, do: status, else: nil
    end
  end

  # Two questions, in order. A post nobody may read is not one anybody may
  # quote, whatever its author set: somebody who posted to their followers
  # chose that audience, and a quote is how a post leaves it. Only then does
  # the author's own answer apply.
  defp answer(status, requester, activity, opts) do
    if status.visibility == :public and allows_quote?(status, requester) do
      accept(status, requester, activity, opts)
    else
      send_back("Reject", status, requester, activity)
    end
  end

  # An approval names the post it approves, so the quoting post has to be in
  # hand before one can be issued. It arrives as the request's `instrument`,
  # which is the quote that has not been published yet -- the asker is waiting
  # on this answer to publish it -- so it is resolved rather than assumed to be
  # already here.
  defp accept(status, requester, activity, opts) do
    with uri when is_binary(uri) <- Helpers.uri_of(activity["instrument"]),
         {:ok, quoting} <- ResolveStatus.resolve(uri, opts) do
      :ok = Quotes.approve(quoting, status)

      send_back("Accept", status, requester, activity, %{
        "result" => Quotes.authorization_uri(quoting, status)
      })
    else
      # Nothing to approve that we can name. Silence rather than a Reject: the
      # answer to "we could not fetch your post" is for them to ask again, and
      # a Reject would tell them the author said no.
      _unreachable -> :ok
    end
  end

  defp send_back(type, status, requester, activity, extra \\ %{}) do
    author = Repo.get(Account, status.account_id)

    document =
      type
      |> Serializer.answer_to(author, activity)
      |> Map.merge(extra)

    Delivery.deliver_to_account(requester, document, author)
  end

  defp allows_quote?(%{quote_policy: :public}, _requester), do: true
  defp allows_quote?(%{quote_policy: :nobody}, _requester), do: false

  defp allows_quote?(%{quote_policy: :followers, account_id: author_id}, requester) do
    Abuuba.Relationships.following?(requester, author_id)
  end

  defp quoting_uri(activity) do
    case activity["object"] do
      %{"object" => object} -> Helpers.uri_of(object)
      _ -> nil
    end
  end

  defp approval_uri(activity) do
    case activity["result"] do
      uri when is_binary(uri) -> uri
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end
end

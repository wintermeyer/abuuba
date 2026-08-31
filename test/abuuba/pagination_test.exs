defmodule Abuuba.PaginationTest do
  @moduledoc """
  What a client gets back when it sends more than one cursor.

  `min_id` and `since_id` are both lower bounds and they mean different
  things: `since_id` asks for the newest page after an id, `min_id` for the
  oldest, which is how a client fills a gap forwards. A client that sends both
  has to get one of the two behaviours rather than a blend of them.

  `Pagination.window/2` resolved the pair one way and three contexts had grown
  their own copy resolving it the other, one of them with a comment arguing
  for its order. This is where that is settled, so the next context to want it
  finds an answer rather than a fourth opinion.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Pagination
  alias Abuuba.Statuses.Status

  setup do
    author = account_fixture()
    posts = for _ <- 1..5, do: status_fixture(%{account_id: author.id})

    %{posts: posts}
  end

  defp ids(page) do
    Status
    |> Pagination.window(page)
    |> Repo.all()
    |> Pagination.reading_order(page)
    |> Enum.map(& &1.id)
  end

  test "min_id wins over since_id, and since_id is not applied as well", %{posts: posts} do
    [first, second, _third, _fourth, fifth] = Enum.map(posts, & &1.id)

    # The reference branches on `min_id` being present and never reads
    # `since_id` in that branch. Applying both would put a second lower bound
    # on the window and cut a hole in the gap `min_id` named.
    assert ids(%{min_id: first, since_id: fifth}) == ids(%{min_id: first})

    # And it is genuinely the `min_id` behaviour: the oldest side of the gap,
    # not the newest.
    assert ids(%{min_id: first, since_id: fifth, limit: 2}) ==
             Enum.reverse([second, Enum.at(Enum.map(posts, & &1.id), 2)])
  end

  test "since_id alone still bounds from the newest end", %{posts: posts} do
    [first, _second, _third, fourth, fifth] = Enum.map(posts, & &1.id)

    assert ids(%{since_id: first, limit: 2}) == [fifth, fourth]
  end

  test "the direction agrees with the bound that was honoured", %{posts: posts} do
    # `direction/1` flips to `:asc` on `min_id`. While `window/2` preferred
    # `since_id`, a client sending both got an ascending page from a
    # `since_id` bound -- neither of the two behaviours it could have asked
    # for, and no test said so.
    [first, _second, _third, _fourth, fifth] = Enum.map(posts, & &1.id)

    assert Pagination.direction(%{min_id: first, since_id: fifth}) == :asc
    assert Pagination.direction(%{since_id: fifth}) == :desc
  end

  test "both bounds are exclusive", %{posts: posts} do
    [first, _second, _third, _fourth, fifth] = Enum.map(posts, & &1.id)

    refute first in ids(%{min_id: first})
    refute fifth in ids(%{max_id: fifth})
  end
end

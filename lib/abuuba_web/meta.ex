defmodule AbuubaWeb.Meta do
  @moduledoc """
  What a page tells a crawler.

  One place rather than a line in each LiveView. The first version of this put
  the tag in with the Open Graph tags of the two pages that needed it, and the
  next six pages that needed it did not get it -- which is the whole of the bug
  this module exists to stop repeating.

  The root layout renders `@robots` when a page sets one, so a page that has
  nothing to say about crawlers says nothing.
  """

  @doc """
  Keep this page out of the search engines, and out of the caches that keep a
  copy after the page has gone.

  Used by anything that shows other people's writing in aggregate -- explore,
  a hashtag, a search, a collection -- because an aggregate cannot honour a
  per-author setting when the authors on it disagree, and the safe reading of a
  disagreement is the stricter one. Used by the personal pages too, where the
  answer does not depend on anybody's setting.
  """
  @spec noindex() :: String.t()
  def noindex, do: "noindex, noarchive"
end

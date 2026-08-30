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

  @doc """
  What a page tells a link preview: the Open Graph tags plus the plain
  description that goes with them.

  The vocabulary was open-coded on each page that wanted it, which is the same
  shape as the bug above and went the same way: `og:description` and the plain
  `description` are one sentence written twice, and the annual report shipped
  without `og:url` because nothing said the list had one.

  `:url` is required for that reason. A preview with no canonical address is
  the one thing a crawler cannot work out for itself.
  """
  @spec open_graph(keyword()) :: [{String.t(), String.t(), String.t()}]
  def open_graph(opts) do
    description = Keyword.get(opts, :description, "")

    [
      {"property", "og:type", Keyword.get(opts, :type, "article")},
      {"property", "og:title", Keyword.fetch!(opts, :title)},
      {"property", "og:description", description},
      {"property", "og:url", Keyword.fetch!(opts, :url)},
      {"name", "description", description}
    ]
  end
end

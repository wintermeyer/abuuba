defmodule AbuubaWeb.EmbedHTML do
  @moduledoc """
  The markup inside an embed frame.

  A whole document rather than a fragment, because it is loaded as its own page
  inside the frame, and deliberately without the navigation, the compose box or
  the socket: none of them mean anything to somebody reading a post on a blog.
  """

  use AbuubaWeb, :html

  embed_templates "embed_html/*"
end

defmodule AbuubaWeb.NotFound do
  @moduledoc """
  Raised when a page names something this server does not have.

  An exception rather than a redirect or a rendered "sorry" page: 404 is the
  answer a crawler, a link preview and another server all need, and a page that
  returned 200 with an apology on it would be indexed as real.
  """

  defexception [:message, plug_status: 404]
end

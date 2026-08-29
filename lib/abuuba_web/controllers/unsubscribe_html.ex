defmodule AbuubaWeb.UnsubscribeHTML do
  @moduledoc """
  The page at the end of an unsubscribe link.
  """

  use AbuubaWeb, :html

  embed_templates "unsubscribe_html/*"

  @doc """
  What a link turns off, said in words.
  """
  def kind_label("notifications"), do: gettext("emails about what happens to your posts")
  def kind_label("digest"), do: gettext("the occasional summary of what you missed")
  def kind_label("all"), do: gettext("every email except the ones about your account")
  def kind_label(kind), do: kind
end

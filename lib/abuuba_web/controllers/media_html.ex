defmodule AbuubaWeb.MediaHTML do
  @moduledoc """
  The bare player another site frames.
  """

  use AbuubaWeb, :html

  alias Abuuba.Media.Upload

  embed_templates "media_html/*"

  @doc """
  Where the file itself is, for the tag that plays it.
  """
  def file_url(attachment), do: Upload.url(attachment)

  @doc """
  Which tag this file wants.
  """
  def kind(%{type: type}) when type in [:video, :gifv], do: :video
  def kind(%{type: :audio}), do: :audio
  def kind(_attachment), do: :image
end

defmodule Abuuba.Trends.Link do
  @moduledoc """
  A hyperlink somebody posted, and what a moderator decided about it.

  Links have no home of their own until preview cards land, and trends needs
  somewhere to record a decision. `provider` is the host, so one judgement can
  cover every article from a site: a news site posting forty stories a day is
  one decision, not forty.

  `trendable` is nullable on purpose. Null is "nobody has looked yet", which is
  a different thing from "no".
  """

  use Ecto.Schema

  schema "trend_links" do
    field :url, :string
    field :provider, :string
    field :title, :string
    field :trendable, :boolean
    field :reviewed_at, :utc_datetime_usec
    field :requested_review_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}
end

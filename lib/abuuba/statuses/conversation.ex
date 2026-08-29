defmodule Abuuba.Statuses.Conversation do
  @moduledoc """
  A thread, gathering the statuses that reply to one another.

  `uri` is null for a conversation that started here. A remote one carries the
  URI of the thread's context, which is how replies arriving from several
  different servers are recognised as belonging to the same conversation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "conversations" do
    field :uri, :string

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:uri])
    |> unique_constraint(:uri)
  end

  @doc """
  Whether the conversation started on this server.
  """
  def local?(%__MODULE__{uri: nil}), do: true
  def local?(%__MODULE__{}), do: false
end

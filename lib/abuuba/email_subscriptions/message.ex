defmodule Abuuba.EmailSubscriptions.Message do
  @moduledoc """
  One thing an account wrote to its list. See `Abuuba.EmailSubscriptions`.

  The row is both the record and the state of the sending: `sent_through_id`
  says how far down the list it has got, and `finished_at` says it is done.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake

  @foreign_key_type Snowflake

  # Long enough for a subject somebody would actually write, short enough that
  # a mail client shows the end of it.
  @max_subject 200

  # Generous for prose and still a limit. This is the one screen that mails
  # people who never signed up here, so "as much as the socket accepts" is not
  # a size to send anybody.
  @max_body 20_000

  schema "email_subscription_messages" do
    field :subject, :string
    field :body, :string
    field :sent_through_id, :integer
    field :recipient_count, :integer, default: 0
    field :finished_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  What the author typed, and nothing else.

  `account_id` is deliberately not castable. It says whose list this goes to
  and whose name is on it, and a form field that decided either would let
  anybody here mail somebody else's subscribers as them. It comes from the
  session, on the struct.

  `sent_through_id`, `recipient_count` and `finished_at` are not castable for a
  narrower version of the same reason: they are the record of what the server
  did, and a record the author can write is not a record.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:subject, :body])
    |> update_change(:subject, &String.trim/1)
    |> update_change(:body, &String.trim/1)
    |> validate_required([:account_id, :subject, :body])
    |> validate_length(:subject, max: @max_subject)
    # An empty update is a message somebody sent by pressing the wrong key, and
    # every address on the list receives it.
    |> validate_length(:subject, min: 1)
    |> validate_length(:body, min: 1, max: @max_body)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  How far the sending has got. Written by the job, never by anybody typing.
  """
  def progress_changeset(message, attrs) do
    cast(message, attrs, [:sent_through_id, :recipient_count, :finished_at])
  end

  @doc """
  The longest subject this accepts, for a form that wants to say so.
  """
  @spec max_subject() :: pos_integer()
  def max_subject, do: @max_subject

  @doc """
  The longest body this accepts, for the same reason.
  """
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body
end

defmodule Abuuba.Instance.TermsOfService do
  @moduledoc """
  One version of the terms people agree to.

  Versioned rather than edited. Changing the text in place would leave every
  account that agreed to it pointing at words they never read, and "what did I
  agree to in March" is the question terms exist to answer.

  The effective date is a date rather than a moment, because terms take effect
  on a day and a timezone-dependent instant is a promise nobody can read off
  the page.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "terms_of_service" do
    field :text, :string
    field :effective_date, :date
    field :published_at, :utc_datetime_usec
    field :notified_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(terms, attrs) do
    terms
    |> cast(attrs, [:text, :effective_date, :published_at, :notified_at])
    |> validate_required([:text, :effective_date])
    |> validate_length(:text, min: 1, max: 100_000)
    |> unique_constraint(:effective_date)
  end

  @doc """
  Whether this version is in force on a given day.
  """
  @spec in_force?(t(), Date.t()) :: boolean()
  def in_force?(%__MODULE__{effective_date: date}, today \\ Date.utc_today()) do
    Date.compare(date, today) != :gt
  end
end

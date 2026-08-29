defmodule Abuuba.Settings.InstanceSetting do
  @moduledoc """
  One instance setting. See `Abuuba.Settings`.
  """

  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}

  schema "instance_settings" do
    field :value, :map

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}
end

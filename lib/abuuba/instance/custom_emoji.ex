defmodule Abuuba.Instance.CustomEmoji do
  @moduledoc """
  A picture somebody can type the name of.

  The shortcode is unique per domain rather than globally, because two servers
  both having a `:blobcat:` is the ordinary case. A global unique index would
  make the second one we heard of unstorable, and posts carrying it would
  render with the wrong picture or none.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @shortcode_format ~r/\A[a-zA-Z0-9_]+\z/

  schema "custom_emojis" do
    field :shortcode, :string
    field :domain, :string
    field :image_url, :string
    field :static_url, :string
    field :visible_in_picker, :boolean, default: true
    field :disabled, :boolean, default: false
    field :category, :string

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc false
  def changeset(emoji, attrs) do
    emoji
    |> cast(attrs, [
      :shortcode,
      :domain,
      :image_url,
      :static_url,
      :visible_in_picker,
      :disabled,
      :category
    ])
    |> validate_required([:shortcode, :image_url])
    |> update_change(:shortcode, &String.trim(&1, ":"))
    |> validate_format(:shortcode, @shortcode_format)
    |> validate_length(:shortcode, max: 64)
    |> unique_constraint(:shortcode, name: :custom_emojis_shortcode_domain_index)
  end

  @doc """
  Whether an emoji belongs to this server rather than to another.
  """
  @spec local?(t()) :: boolean()
  def local?(%__MODULE__{domain: nil}), do: true
  def local?(%__MODULE__{}), do: false
end

defmodule Abuuba.OAuth.Application do
  @moduledoc """
  A registered client application.

  The client secret is stored hashed. It is a credential, and an app that has
  lost its secret re-registers rather than asking us to read it back.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.User
  alias Abuuba.OAuth.Scopes

  # What a client sends when it has no web callback of its own. The spec's
  # out-of-band value, which Mastodon accepts and clients still use.
  @oob_uri "urn:ietf:wg:oauth:2.0:oob"

  schema "oauth_applications" do
    field :name, :string
    field :website, :string
    field :client_id, :string
    field :hashed_client_secret, :string
    field :redirect_uris, :string, default: ""
    field :scopes, :string, default: "read"
    field :vapid_key, :string

    field :client_secret, :string, virtual: true, redact: true

    belongs_to :owner_user, User

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:name, :website, :redirect_uris, :scopes, :owner_user_id])
    |> validate_required([:name, :redirect_uris])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_redirect_uris()
    |> validate_scopes()
    |> unique_constraint(:client_id)
  end

  @doc """
  The out-of-band redirect URI.
  """
  def oob_uri, do: @oob_uri

  @doc """
  The redirect URIs this application registered.
  """
  @spec redirect_uri_list(t()) :: [String.t()]
  def redirect_uri_list(%__MODULE__{redirect_uris: uris}) do
    String.split(uris || "", ["\n", " "], trim: true)
  end

  @doc """
  Whether a redirect URI is one this application registered.

  Compared exactly, never by prefix. A prefix match would let an attacker who
  can register `https://app.example/cb` redirect a code to
  `https://app.example/cb.evil.example`, and open redirects are how
  authorization codes get stolen.
  """
  @spec registered_redirect_uri?(t(), String.t()) :: boolean()
  def registered_redirect_uri?(%__MODULE__{} = application, uri) do
    uri in redirect_uri_list(application)
  end

  defp validate_redirect_uris(changeset) do
    case get_field(changeset, :redirect_uris) do
      nil ->
        changeset

      uris ->
        parsed = String.split(uris, ["\n", " "], trim: true)

        cond do
          parsed == [] ->
            add_error(changeset, :redirect_uris, "must have at least one entry")

          Enum.all?(parsed, &valid_redirect_uri?/1) ->
            put_change(changeset, :redirect_uris, Enum.join(parsed, "\n"))

          true ->
            add_error(changeset, :redirect_uris, "is not a valid URI")
        end
    end
  end

  # A custom scheme is normal here: a mobile client registers something like
  # `myapp://oauth` because it has no web server to be redirected to.
  defp valid_redirect_uri?(@oob_uri), do: true

  defp valid_redirect_uri?(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> scheme != ""
      _ -> false
    end
  end

  defp validate_scopes(changeset) do
    case get_field(changeset, :scopes) do
      nil ->
        changeset

      scopes ->
        case Scopes.parse(scopes) do
          {:ok, parsed} ->
            put_change(changeset, :scopes, Scopes.to_string(parsed))

          {:error, unknown} ->
            add_error(changeset, :scopes, "unknown: #{Enum.join(unknown, " ")}")
        end
    end
  end
end

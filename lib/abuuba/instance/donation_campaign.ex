defmodule Abuuba.Instance.DonationCampaign do
  @moduledoc """
  The appeal an admin asks clients to show, if there is one.

  Mastodon fetches this from a service its own project runs, which decides for
  every server what its users are asked to fund. abuuba reads it from this
  server's settings instead: the person who pays for the machine writes the
  message, and no third party learns who is running what by being asked.

  ## The id is the content

  Clients remember which campaign somebody dismissed. If the id were fixed, an
  admin who rewrote the appeal would find nobody ever saw the new one; if it
  changed on every read, a dismissal would never stick. So it is a digest of
  the text: editing the appeal makes it a new campaign, and reading it twice
  does not.

  Nothing here is a payment. The admin gives a link and it is followed off this
  server, which is the whole of abuuba's involvement in the money.
  """

  use Gettext, backend: AbuubaWeb.Gettext

  alias Abuuba.Settings

  @keys ~w(message button_text url)

  @typedoc "A campaign as clients receive it."
  @type t :: %{String.t() => String.t()}

  @doc """
  The campaign to show, or `nil` where the admin has not written one.

  A campaign missing either the message or the link is treated as not written:
  half of one renders as a button with nowhere to go or a message with no way
  to act on it, and an admin mid-edit should not be shipping that to everybody.

  A link that is not `http` or `https` is treated the same way. It is rendered
  as a link by every client on this server, so a `javascript:` one would be an
  admin-shaped hole in all of them, and the admin who fat-fingered it should
  find nothing showing rather than something dangerous.
  """
  @spec current(String.t() | nil) :: t() | nil
  def current(locale \\ nil) do
    fields = Map.new(@keys, &{&1, setting(&1)})

    if fields["message"] != "" and valid_url?(fields["url"]) do
      fields
      |> Map.put("id", id_for(fields))
      |> Map.put("locale", locale || Gettext.get_locale(AbuubaWeb.Gettext))
      |> Map.update!("button_text", &default_button_text/1)
    end
  end

  @doc """
  Whether a URL is one an admin may point the button at.
  """
  @spec valid_url?(String.t()) :: boolean()
  def valid_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  def valid_url?(_url), do: false

  defp setting(key) do
    "donation_campaign_#{key}" |> Settings.get() |> to_string() |> String.trim()
  end

  # The one string here this server writes rather than the admin, so it is the
  # one that has to be translated.
  defp default_button_text(""), do: gettext("Donate")
  defp default_button_text(text), do: text

  defp id_for(fields) do
    @keys
    |> Enum.map_join("\n", &Map.fetch!(fields, &1))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end
end

defmodule Abuuba.PreviewCards.EndpointCache do
  @moduledoc """
  Where a site's oEmbed endpoint is, remembered per host.

  Discovering it means fetching and parsing the site's HTML. Doing that per
  link means every article from one newspaper pays for it again, where the
  endpoint is a property of the site and changes about never. Cached for a day,
  the second link from a domain costs one request instead of two.

  "This host has none" is cached too, and that is the half people forget:
  without it, every link to a site without oEmbed pays for the discovery on
  every single post.
  """

  import Ecto.Query

  alias Abuuba.Repo

  @ttl_hours 24

  @doc """
  What is known about a host: `{:ok, endpoint | nil}`, or `:miss` where nothing
  has been looked up lately.
  """
  @spec lookup(String.t()) ::
          {:ok, %{endpoint: String.t() | nil, format: String.t() | nil}} | :miss
  def lookup(host) do
    now = DateTime.utc_now()

    from(e in "oembed_endpoints",
      where: e.host == ^normalise(host) and e.expires_at > ^now,
      select: %{endpoint: e.endpoint, format: e.format}
    )
    |> Repo.one()
    |> case do
      nil -> :miss
      row -> {:ok, row}
    end
  end

  @doc """
  Remembers what was discovered, including that there was nothing.
  """
  @spec put(String.t(), String.t() | nil, String.t() | nil) :: :ok
  def put(host, endpoint, format \\ "json") do
    now = DateTime.utc_now()
    host = normalise(host)

    Repo.insert_all(
      "oembed_endpoints",
      [
        [
          host: host,
          endpoint: endpoint,
          format: format,
          expires_at: DateTime.add(now, @ttl_hours, :hour),
          inserted_at: now,
          updated_at: now
        ]
      ],
      conflict_target: [:host],
      on_conflict:
        from(e in "oembed_endpoints",
          update: [
            set: [
              endpoint: ^endpoint,
              format: ^format,
              expires_at: ^DateTime.add(now, @ttl_hours, :hour),
              updated_at: ^now
            ]
          ]
        )
    )

    :ok
  end

  @doc """
  Forgets a host, as the day would have.
  """
  @spec expire(String.t()) :: :ok
  def expire(host) do
    from(e in "oembed_endpoints", where: e.host == ^normalise(host))
    |> Repo.delete_all()

    :ok
  end

  @doc "How long an entry lives."
  @spec ttl_hours() :: pos_integer()
  def ttl_hours, do: @ttl_hours

  defp normalise(host), do: host |> to_string() |> String.downcase()
end

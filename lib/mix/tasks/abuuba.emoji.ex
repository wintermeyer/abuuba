defmodule Mix.Tasks.Abuuba.Emoji do
  @shortdoc "Custom emoji: list, copy from another server, purge"

  @moduledoc """
  The custom emoji this server knows about, its own and other people's.

      mix abuuba.emoji list
      mix abuuba.emoji import --from mastodon.social --prefix soc_
      mix abuuba.emoji purge --domain gone.example --dry-run

  ## list

  Local emoji first, then a count per server for the ones this server has seen
  in other people's posts.

  ## import

  Copies what another server publishes at `/api/v1/custom_emojis` into this
  server's own set, so they appear in the picker here.

  `--prefix` puts something in front of every shortcode. Without it, a
  shortcode already taken here is skipped rather than overwritten: `:blobcat:`
  here and `:blobcat:` there are two different pictures with the same name, and
  swapping one for the other changes what every post that used it looks like.

  Only the address is copied, not the image, which is what this server already
  does with every emoji it has seen from elsewhere — the picture is served from
  where it lives.

  ## purge

  Removes every emoji this server has recorded from one `--domain`. They are
  addresses rather than pictures — the image is served from where it lives — so
  purging one removes this server's note of it and nothing else. Takes
  `--dry-run`, and the count it prints comes from the same query the deletion
  uses.

  ## Not here

  Uploading from a tarball, which needs somewhere to put the images.
  """

  use Mix.Task

  import Ecto.Query

  alias Abuuba.Federation.HTTP
  alias Abuuba.Instance
  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Ops
  alias Abuuba.Repo

  @commands ~w(list import purge)

  @switches [from: :string, prefix: :string, domain: :string, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Ops.start!()

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches)

    case rest do
      ["list" | _rest] -> list()
      ["import" | _rest] -> import_from(opts)
      ["purge" | _rest] -> purge(opts)
      [command | _rest] -> Ops.unknown(command, @commands)
      [] -> Mix.raise("Say what to do: #{Enum.join(@commands, ", ")}")
    end
  end

  # Through the ordinary outbound layer, so this inherits the SSRF guards, the
  # circuit breaker and the timeouts rather than growing its own.
  defp fetch(domain) do
    case HTTP.get_rest_json("https://" <> domain <> "/api/v1/custom_emojis") do
      {:ok, list} when is_list(list) -> list
      {:ok, _other} -> Mix.raise("#{domain} did not answer with a list of emoji.")
      {:error, reason} -> Mix.raise("Could not ask #{domain}: #{inspect(reason)}")
    end
  end

  defp local_shortcodes do
    CustomEmoji |> where([e], is_nil(e.domain)) |> select([e], e.shortcode) |> Repo.all()
  end

  # Recorded as this server's own, because that is what an import is for: an
  # emoji filed under the server it came from would stay out of the picker,
  # which is the only reason to copy one.
  defp record(shortcode, emoji) do
    attrs = %{
      shortcode: shortcode,
      domain: nil,
      image_url: emoji["url"],
      static_url: emoji["static_url"] || emoji["url"],
      visible_in_picker: true
    }

    match?({:ok, _emoji}, Instance.put_custom_emoji(attrs))
  end

  defp list do
    local =
      CustomEmoji
      |> where([e], is_nil(e.domain))
      |> order_by([e], asc: e.shortcode)
      |> Repo.all()

    Mix.shell().info("Here: #{length(local)}")
    Enum.each(local, fn emoji -> Mix.shell().info("  :#{emoji.shortcode}:") end)

    remote =
      CustomEmoji
      |> where([e], not is_nil(e.domain))
      |> group_by([e], e.domain)
      |> select([e], {e.domain, count(e.id)})
      |> order_by([e], desc: count(e.id))
      |> Repo.all()

    Mix.shell().info("\nSeen from elsewhere:")
    Enum.each(remote, fn {domain, count} -> Mix.shell().info("  #{count}\t#{domain}") end)
  end

  defp import_from(opts) do
    domain = Keyword.get(opts, :from) || Mix.raise("Say where from: --from example.social")
    prefix = Keyword.get(opts, :prefix, "")

    published = fetch(domain)
    taken = MapSet.new(local_shortcodes())

    {added, skipped} =
      Enum.reduce(published, {0, 0}, fn emoji, {added, skipped} ->
        shortcode = prefix <> to_string(emoji["shortcode"])

        cond do
          MapSet.member?(taken, shortcode) -> {added, skipped + 1}
          Ops.dry_run?(opts) -> {added + 1, skipped}
          record(shortcode, emoji) -> {added + 1, skipped}
          true -> {added, skipped + 1}
        end
      end)

    Ops.report(Ops.dry_run?(opts), added, "emoji")

    if skipped > 0 do
      Mix.shell().info("#{skipped} left alone: that shortcode is already taken here.")
    end
  end

  defp purge(opts) do
    domain = Keyword.get(opts, :domain) || Mix.raise("Say which server: --domain example.social")

    query = where(CustomEmoji, [e], e.domain == ^domain)

    if Ops.dry_run?(opts) do
      Ops.report(true, Repo.aggregate(query, :count), "emoji")
    else
      {count, _returned} = Repo.delete_all(query)

      Ops.report(false, count, "emoji")
    end
  end
end

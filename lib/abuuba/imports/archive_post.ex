defmodule Abuuba.Imports.ArchivePost do
  @moduledoc """
  One activity out of an archive's outbox, as a post here.

  ## The date is kept and the address is not

  A post's id here is a snowflake, which is its date. Minting one from the
  original `published` time is what makes an imported profile read in the order
  it was written instead of arriving as a wall of posts all dated today.

  The address cannot be kept: it names a domain this server is not. So the post
  gets one of ours, and is marked as imported — which is what keeps it out of
  everybody's timeline and off the network, and what lets the interface say
  plainly that this is a copy.

  ## What is skipped, and said out loud

  A boost names somebody else's post by address and the archive does not
  contain it, so re-creating one would mean fetching from a server that may be
  gone; those are reported rather than guessed at. So is a poll, whose votes
  cannot be carried over in any form that would still be true.
  """

  alias Abuuba.Importer.Archive
  alias Abuuba.Media
  alias Abuuba.Snowflake
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Formatter

  @public "https://www.w3.org/ns/activitystreams#Public"

  @doc """
  Imports one outbox activity.

  `{:ok, status}`, `:skip` for something this deliberately does not carry over,
  or `{:error, reason}` for one that could not be read.
  """
  @spec import(map(), map(), Archive.t()) :: {:ok, term()} | :skip | {:error, atom()}
  def import(account, %{"type" => "Create", "object" => object}, archive)
      when is_map(object) do
    create(account, object, archive)
  end

  # A bare object rather than an activity, which is what some exporters write.
  def import(account, %{"type" => type} = object, archive) when type in ~w(Note) do
    create(account, object, archive)
  end

  def import(_account, %{"type" => "Announce"}, _archive), do: {:error, :boosts_are_not_carried}

  def import(_account, _unknown, _archive), do: :skip

  @doc """
  A line naming the item, for a failure somebody has to make sense of.
  """
  @spec describe(map()) :: String.t()
  def describe(%{"object" => %{"published" => published}}) when is_binary(published),
    do: "post from #{published}"

  def describe(%{"published" => published}) when is_binary(published),
    do: "post from #{published}"

  def describe(%{"type" => type}) when is_binary(type), do: "#{type} activity"
  def describe(_activity), do: "an item"

  ## Making one

  defp create(_account, %{"type" => "Question"}, _archive), do: {:error, :polls_are_not_carried}

  defp create(account, object, archive) do
    with {:ok, published} <- published_at(object),
         {:ok, media} <- attachments(account, object, archive) do
      attrs = %{
        account_id: account.id,
        text: text(object),
        spoiler_text: object["summary"] || "",
        sensitive: object["sensitive"] == true,
        language: language(object),
        visibility: visibility(object),
        local: true,
        imported_at: DateTime.utc_now(),
        inserted_at: published,
        updated_at: published,
        ordered_media_attachment_ids: Enum.map(media, & &1.id)
      }

      case insert(attrs, published, 0) do
        {:ok, status} ->
          Media.attach(status, Enum.map(media, & &1.id))

          {:ok, status}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A snowflake is a time and a sequence, and somebody posting a thread wrote
  # several posts in the same millisecond. The next sequence is what those are
  # for; without this the second post of every thread would be reported as one
  # that could not be saved.
  @sequences 32

  defp insert(attrs, published, sequence) when sequence < @sequences do
    case Statuses.import_status(Map.put(attrs, :id, Snowflake.id_at(published, sequence))) do
      {:ok, status} -> {:ok, status}
      {:error, changeset} -> retry(changeset, attrs, published, sequence)
    end
  end

  defp insert(_attrs, _published, _sequence), do: {:error, :could_not_be_saved}

  defp retry(changeset, attrs, published, sequence) do
    if Keyword.has_key?(changeset.errors, :id) do
      insert(attrs, published, sequence + 1)
    else
      {:error, :could_not_be_saved}
    end
  end

  defp published_at(%{"published" => published}) when is_binary(published) do
    case DateTime.from_iso8601(published) do
      {:ok, at, _offset} -> {:ok, at}
      _not_a_time -> {:error, :no_date}
    end
  end

  # Without a date there is no id, because the id is the date. Guessing one
  # would put a post from 2015 at the top of the author's profile.
  defp published_at(_object), do: {:error, :no_date}

  # The archive holds HTML, because that is what the old server rendered. A post
  # of this account's own is stored as plain text here and turned into HTML on
  # the way out, so the markup has to come back off — otherwise the renderer
  # escapes it and the reader sees `<p>` in the middle of a sentence.
  #
  # Turning it back into text also puts it through the same linking every other
  # post of theirs goes through, so a mention or a tag written in 2019 becomes a
  # link to the account or the tag as it is here.
  defp text(object) do
    object["content"] |> to_string() |> Formatter.sanitize() |> to_plain_text()
  end

  defp to_plain_text(html) do
    html
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{</p>\s*<p>}i, "\n\n")
    |> String.replace(~r{</?p>}i, "")
    |> strip_tags()
    |> String.trim()
  end

  # Anchors and everything else the old server wrapped around the words, and
  # the entities it escaped them with. The words are what somebody wrote; the
  # markup was that server's rendering of them and this one does its own.
  defp strip_tags(html) do
    case LazyHTML.from_fragment(html) do
      %LazyHTML{} = document -> LazyHTML.text(document)
      _unparsable -> String.replace(html, ~r{<[^>]*>}, "")
    end
  rescue
    _unparsable -> String.replace(html, ~r{<[^>]*>}, "")
  end

  defp language(%{"contentMap" => map}) when is_map(map) do
    map |> Map.keys() |> List.first()
  end

  defp language(_object), do: nil

  defp visibility(object) do
    to = addressees(object["to"])
    cc = addressees(object["cc"])

    cond do
      @public in to -> :public
      @public in cc -> :unlisted
      Enum.any?(to, &String.ends_with?(&1, "/followers")) -> :private
      true -> :direct
    end
  end

  defp addressees(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp addressees(value) when is_binary(value), do: [value]
  defp addressees(_value), do: []

  # The exporter rewrites every attachment address to a path inside the
  # archive, which is what makes a post and its pictures findable together
  # without a network. A picture that is not in there is a picture that cannot
  # be imported, and the post is not worth losing over it.
  defp attachments(account, %{"attachment" => attachments}, archive) when is_list(attachments) do
    attachments
    |> Enum.flat_map(&attach(account, &1, archive))
    |> then(&{:ok, &1})
  end

  defp attachments(_account, _object, _archive), do: {:ok, []}

  defp attach(account, attachment, archive) when is_map(attachment) do
    case Archive.file(archive, attachment["url"]) do
      nil ->
        []

      path ->
        # The type has to be said out loud: the upload pipeline reads it from
        # the request rather than sniffing the file, and there is no request
        # here. The archive states it; the file name answers for the exporters
        # that do not.
        upload = %{
          path: path,
          filename: Path.basename(path),
          content_type: attachment["mediaType"] || MIME.from_path(path)
        }

        case Media.upload(account, upload, %{"description" => attachment["name"]}) do
          {:ok, stored} -> [stored]
          {:error, _reason} -> []
        end
    end
  end

  defp attach(_account, _attachment, _archive), do: []
end

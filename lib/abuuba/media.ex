defmodule Abuuba.Media do
  @moduledoc """
  Uploaded files and the state of processing them.

  See `Abuuba.Media.Attachment` for why an attachment is not owned by a status.
  The actual transcoding and storage arrive later; this is the record that
  tracks them.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.HTTP
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Pipeline
  alias Abuuba.Media.ProcessingWorker
  alias Abuuba.Media.Storage
  alias Abuuba.Media.Upload
  alias Abuuba.Moderation.Domains
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status

  @doc """
  Records an upload. Attaching it to a status comes later, if at all.
  """
  @spec create_attachment(map()) :: {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()}
  def create_attachment(attrs) do
    %Attachment{} |> Attachment.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Fetches an attachment, or `nil`.
  """
  @spec get_attachment(integer()) :: Attachment.t() | nil
  def get_attachment(id), do: Repo.get(Attachment, id)

  @doc """
  Fetches an attachment belonging to `account` that is not yet posted.

  This is the lookup the compose flow needs: a client hands back an id it was
  given for an upload, and only the uploader may attach it. Without the account
  check, one person could hang another person's photo on their own post.
  """
  @spec get_own_unattached(Account.t() | integer(), integer()) :: Attachment.t() | nil
  def get_own_unattached(%Account{id: id}, attachment_id),
    do: get_own_unattached(id, attachment_id)

  def get_own_unattached(account_id, attachment_id) do
    Attachment
    |> where([a], a.id == ^attachment_id)
    |> where([a], a.account_id == ^account_id)
    |> where([a], is_nil(a.status_id))
    |> Repo.one()
  end

  @doc """
  Updates the alt text.
  """
  @spec describe(Attachment.t(), String.t() | nil) ::
          {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()}
  def describe(%Attachment{} = attachment, description) do
    attachment
    |> Attachment.description_changeset(%{description: description})
    |> Repo.update()
  end

  @doc """
  Records how processing went.
  """
  @spec set_processing(Attachment.t(), atom(), map()) ::
          {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()}
  def set_processing(attachment, state, attrs \\ %{})

  def set_processing(%Attachment{} = attachment, :failed, reason)
      when is_atom(reason) or is_binary(reason) do
    # The reason goes into the meta rather than into a column of its own: it is
    # read by whoever is looking at why one upload failed, which is rare, and a
    # column would be null on every row that worked.
    meta = Map.put(attachment.meta || %{}, "error", to_string(reason))

    set_processing(attachment, :failed, %{meta: meta})
  end

  def set_processing(%Attachment{} = attachment, state, attrs) do
    attachment
    |> Attachment.changeset(Map.put(attrs, :processing, state))
    |> Repo.update()
  end

  @doc """
  Records the media another server says a post carries.

  Addresses rather than files: the bytes are pulled by the media proxy the
  first time a reader here opens the post, so a server does not spend its disk
  on attachments nobody reads. `file_file_name` is set because that is what
  gives the row a storage key to cache under later — it names where the copy
  will go, not a file that exists.

  A row already here for the same address is kept rather than replaced. An
  edited post arrives as the whole object again, so replacing every row would
  churn the ids on every edit — invalidating every cached `/media_proxy/<id>`
  URL a browser or CDN holds, re-pulling bytes this server already has, and
  orphaning the old file, which nothing can reclaim once the row naming it is
  gone. Only what actually disappeared is deleted, and its file goes with it.
  """
  @spec replace_remote(Status.t(), [map()]) :: {:ok, Status.t()}
  def replace_remote(%Status{} = status, documents) do
    Repo.transaction(fn ->
      existing =
        Attachment
        |> where([a], a.status_id == ^status.id)
        |> Repo.all()
        |> Map.new(&{&1.remote_url, &1})

      kept =
        documents
        |> Enum.map(&upsert_remote(status, &1, existing))
        |> Enum.reject(&is_nil/1)

      # Whatever the sender no longer lists. Its file goes too: the key is
      # derived from the row, so a row deleted without its bytes leaves bytes
      # nothing can ever name again.
      existing
      |> Map.drop(Enum.map(documents, & &1[:remote_url]))
      |> Map.values()
      |> Enum.each(&drop_remote/1)

      status
      |> Ecto.Changeset.change(ordered_media_attachment_ids: Enum.map(kept, & &1.id))
      |> Repo.update!()
    end)
  end

  # Through the storage layer rather than the upload root: a cached copy of
  # somebody else's picture lives under the key its row derives, and deleting
  # the row without the bytes leaves bytes nothing can name.
  defp drop_remote(%Attachment{} = attachment) do
    Enum.each([:original, :small], fn style ->
      attachment |> Storage.key_for(style) |> Storage.delete()
    end)

    Repo.delete(attachment)
  end

  defp upsert_remote(status, attrs, existing) do
    attrs = bounded(attrs)

    case Map.get(existing, attrs[:remote_url]) do
      %Attachment{} = already ->
        # Its description or dimensions may have changed with the edit; its id,
        # and therefore everything cached under it, must not.
        already |> Attachment.changeset(attrs) |> Repo.update() |> ok_or_nil(already)

      nil ->
        insert_remote(status, attrs)
    end
  end

  defp ok_or_nil({:ok, attachment}, _fallback), do: attachment
  defp ok_or_nil({:error, _changeset}, fallback), do: fallback

  defp insert_remote(status, attrs) do
    attrs =
      Map.merge(attrs, %{
        account_id: status.account_id,
        status_id: status.id,
        type: type_for(attrs[:file_content_type]),
        # Complete because there is nothing here to process: the other server
        # did that, and what this row holds is where to find the result.
        processing: :complete,
        file_file_name: file_name_for(attrs[:remote_url]),
        # A name for the small style too, so it has a storage key at all.
        # Without one `Storage.key_for(_, :small)` answers nil, the proxy
        # refuses, and every federated picture renders as a broken thumbnail —
        # which is the URL every client asks for first.
        thumbnail_file_name: file_name_for(attrs[:remote_url])
      })

    case Repo.insert(Attachment.changeset(%Attachment{}, attrs)) do
      {:ok, attachment} -> attachment
      {:error, _changeset} -> nil
    end
  end

  # Cut to what the columns hold rather than left to raise. These are strings a
  # stranger chose, and `varchar(255)` overflowing inside a delivery job takes
  # the whole job with it — on an edit, every retry of it.
  defp bounded(attrs) do
    attrs
    |> Map.update(:file_content_type, nil, &clip(&1, 255))
    |> Map.update(:blurhash, nil, &clip(&1, 255))
    |> Map.update(:description, nil, &clip(&1, Attachment.max_description()))
    |> Map.update(:remote_url, nil, &clip(&1, 2048))
  end

  # NULs go with the length: Postgres refuses them in a text column, and one in
  # a URL is somebody trying rather than somebody mistaken.
  defp clip(value, limit) when is_binary(value) do
    value |> String.replace("\u0000", "") |> String.slice(0, limit)
  end

  defp clip(value, _limit), do: value

  # The kind a client needs to know before it decides how to show the thing.
  # `unknown` rather than a guess: a client that is told nothing renders a
  # link, and one told the wrong thing renders a broken player.
  # A GIF is an image here rather than a `gifv`: that type means "a video a
  # client should loop silently", and it is what you get after transcoding one.
  # This server stores the GIF as it arrived, and a client told `gifv` builds a
  # video player around a picture.
  defp type_for("image/" <> _rest), do: :image
  defp type_for("video/" <> _rest), do: :video
  defp type_for("audio/" <> _rest), do: :audio
  defp type_for(_other), do: :unknown

  # Named after the file at the other end, so the cached copy lands somewhere
  # with the right extension for whatever serves it.
  defp file_name_for(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> Path.basename()
    |> case do
      "" -> "remote"
      name -> String.slice(name, 0, 200)
    end
  end

  defp file_name_for(_url), do: "remote"

  @doc """
  Pulls one style of a remote attachment onto this server's own storage.

  The one place that does this. The proxy reaches it when a reader asks for a
  picture nobody has fetched yet, and `mix abuuba.media refresh` reaches it to
  warm one ahead of that — two callers, one set of rules about what may be
  fetched and where it is put. Two paths would be two answers to "is this
  cached", and the second one would drift.

  `{:ok, body}` where it was fetched and stored, so the caller serving a reader
  does not have to read back what it just wrote. `:already` where the file is
  there. `{:error, reason}` otherwise, and never an exception: a picture that
  will not come is a picture that is not there as far as a reader is concerned.
  """
  @spec cache_remote(Attachment.t(), :original | :small) ::
          {:ok, binary()} | :already | {:error, term()}
  def cache_remote(%Attachment{} = attachment, style \\ :original, opts \\ []) do
    key = Storage.key_for(attachment, style)

    cond do
      is_nil(key) -> {:error, :no_such_style}
      Storage.exists?(key) -> :already
      not remote?(attachment) -> {:error, :not_remote}
      rejected_domain?(attachment) -> {:error, :rejected_domain}
      true -> fetch_into(attachment, key, style, opts)
    end
  end

  # An admin who ticked "reject media" on a domain block means no bytes from
  # that server land on this disk. Asked here because this is the one door --
  # the media proxy and `mix abuuba.media refresh` both come through it -- so a
  # post that arrived before the block was written stops fetching too, without
  # anybody having to go back and clean up.
  #
  # Matched on the author's domain rather than the file's host: attachments
  # routinely live on a separate CDN name, and matching the host would miss
  # most of them.
  defp rejected_domain?(%Attachment{account_id: nil}), do: false

  defp rejected_domain?(%Attachment{account_id: account_id}) do
    case Repo.one(from(a in Account, where: a.id == ^account_id, select: a.domain)) do
      nil -> false
      domain -> Domains.reject_media?(domain)
    end
  end

  @doc """
  Whether an attachment is a copy of somebody else's.

  A local one whose file is missing is missing: going to the network for it
  would be this server asking somebody else for its own data.
  """
  @spec remote?(Attachment.t()) :: boolean()
  def remote?(%Attachment{remote_url: url}), do: is_binary(url) and url != ""

  @doc """
  Cached copies whose file is not on this server, oldest first.
  """
  @spec uncached_remote(keyword()) :: [Attachment.t()]
  def uncached_remote(opts \\ []) do
    query =
      from(a in Attachment,
        where: not is_nil(a.remote_url) and a.remote_url != "",
        where: not is_nil(a.file_file_name),
        order_by: [asc: a.id]
      )

    query
    |> then(fn q ->
      case Keyword.get(opts, :days) do
        days when is_integer(days) and days > 0 ->
          where(q, [a], a.inserted_at > ^DateTime.add(DateTime.utc_now(), -days, :day))

        _all ->
          q
      end
    end)
    |> then(fn q ->
      case Keyword.get(opts, :limit) do
        limit when is_integer(limit) and limit > 0 -> limit(q, ^limit)
        _all -> q
      end
    end)
    |> Repo.all()
    |> Enum.reject(fn attachment ->
      attachment |> Storage.key_for(:original) |> Storage.exists?()
    end)
  end

  # The thumbnail where the record kept its address, and the full file
  # otherwise: not every server publishes a small version, and asking for one
  # that was never advertised gets a 404 from them rather than a picture.
  defp source_url(%Attachment{} = attachment, :small) do
    case get_in(attachment.meta || %{}, ["preview_remote_url"]) do
      url when is_binary(url) and url != "" -> url
      _ -> attachment.remote_url
    end
  end

  defp source_url(%Attachment{remote_url: url}, _style), do: url

  defp fetch_into(attachment, key, style, opts) do
    # A media-sized ceiling: the default is a megabyte, written for documents,
    # and a photograph truncated to it is a corrupt file.
    #
    # One byte above the ceiling rather than the ceiling itself, so that "as
    # long as we allow" and "longer than we allow" can be told apart. Asking
    # for exactly the maximum makes a file of precisely that size and a file of
    # a gigabyte arrive identically, and the gigabyte would be stored as a
    # truncated picture that nothing downstream can distinguish from a small
    # one -- cached, served, and wrong for as long as the row exists.
    limit = Upload.max_bytes()
    opts = Keyword.put(opts, :max_bytes, limit + 1)

    case HTTP.get_document(source_url(attachment, style), opts) do
      {:ok, %{body: body}} when byte_size(body) > limit ->
        {:error, :too_large}

      {:ok, %{body: body}} ->
        store(key, body)

        {:ok, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The storage layer takes a path rather than bytes, because everything else
  # that writes to it has a file already. Written and handed over rather than
  # kept, so the caching backend is the one that decides where it ends up.
  defp store(key, body) do
    path = Path.join(System.tmp_dir!(), "abuuba-cache-#{System.unique_integer([:positive])}")

    try do
      File.write!(path, body)
      Storage.put(key, path)
    after
      File.rm(path)
    end
  rescue
    # A cache that could not be written is a slow page, not a broken one.
    _error -> :ok
  end

  @doc """
  How many bytes of other people's media this server is holding.
  """
  @spec cached_bytes() :: non_neg_integer()
  def cached_bytes do
    from(a in Attachment,
      where: a.remote_url != "" and not is_nil(a.file_file_name),
      select: sum(coalesce(a.file_file_size, 0) + coalesce(a.thumbnail_file_size, 0))
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Drops copies of other people's media older than `days`.

  Only theirs. Remote media is re-fetchable from where it came from, which is
  what makes dropping it safe; a local file has nowhere to be fetched back from
  and dropping one is deleting somebody's picture.

  The row stays, with its `remote_url` intact and no local file, so the
  attachment still renders as itself and the bytes can be fetched again when
  somebody looks at the post. Zero keeps everything, because an admin who has
  not chosen a retention has not chosen to delete anything.
  """
  @spec vacuum_remote_media(non_neg_integer(), DateTime.t()) :: {:ok, non_neg_integer()}
  def vacuum_remote_media(days, now \\ DateTime.utc_now())

  def vacuum_remote_media(days, _now) when days <= 0, do: {:ok, 0}

  def vacuum_remote_media(days, now) do
    cutoff = DateTime.add(now, -days, :day)

    stale =
      from(a in Attachment,
        where: a.remote_url != "" and not is_nil(a.file_file_name),
        where: a.inserted_at < ^cutoff
      )
      |> Repo.all()

    Enum.each(stale, &drop_files/1)

    {:ok, length(stale)}
  end

  @doc """
  Deletes every attachment an account owns, bytes and rows alike.

  For an account being closed. `media_attachments.account_id` is
  `nilify_all`, so the cascade that takes somebody's posts leaves their
  pictures behind as rows owned by nobody and files nothing names -- and the
  sweep that would reclaim them is a mix task an admin has to remember. The
  settings page tells somebody their account is deleted; this is the part of
  that promise that was not being kept.

  Done before the account row goes, while `account_id` still points at it.
  """
  @spec discard_for_account(integer()) :: {:ok, non_neg_integer()}
  def discard_for_account(account_id) do
    attachments = Attachment |> where([a], a.account_id == ^account_id) |> Repo.all()

    Enum.each(attachments, fn attachment ->
      drop_stored_files(attachment)
      Repo.delete(attachment, stale_error_field: :id)
    end)

    {:ok, length(attachments)}
  end

  @doc """
  Deletes an attachment's stored bytes, leaving the row.

  Public because the remote-post vacuum needs it: the row goes with its status
  through the foreign key, and a row deleted without its bytes leaves bytes
  nothing can ever name again.
  """
  @spec drop_stored_files(Attachment.t()) :: :ok
  def drop_stored_files(%Attachment{} = attachment) do
    Storage.delete(Storage.key_for(attachment, :original))
    Storage.delete(Storage.key_for(attachment, :small))

    :ok
  end

  defp drop_files(%Attachment{} = attachment) do
    Storage.delete(Storage.key_for(attachment, :original))
    Storage.delete(Storage.key_for(attachment, :small))

    attachment
    |> Ecto.Changeset.change(file_file_name: nil, thumbnail_file_name: nil)
    |> Repo.update()
  end

  @doc """
  Records what processing produced and marks the attachment complete.

  One write rather than one per field: an attachment that is complete but whose
  dimensions have not landed yet is one a client renders at the wrong size.
  """
  @spec finish_processing(Attachment.t(), map()) ::
          {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()}
  def finish_processing(%Attachment{} = attachment, attrs) do
    thumbnail = Map.get(attrs, :thumbnail)
    previous_thumbnail = Storage.key_for(attachment, :small)

    changes =
      %{
        processing: :complete,
        meta: Map.get(attrs, :meta, attachment.meta),
        blurhash: Map.get(attrs, :blurhash),
        type: Map.get(attrs, :type, attachment.type),
        file_content_type: Map.get(attrs, :file_content_type, attachment.file_content_type)
      }
      |> with_thumbnail(thumbnail)

    with {:ok, saved} <- attachment |> Attachment.changeset(changes) |> Repo.update() do
      # Processing an attachment a second time -- a retry, or the bulk refresh
      # `mix abuuba.media refresh` runs -- derives a new thumbnail under a new
      # random name. The row then names that one, and the one it replaced is
      # unreachable: no sweep, no delete and no account closure can find a file
      # whose only reference has just been overwritten. Removed after the row
      # is saved, so a failure leaves the old picture in place rather than the
      # row pointing at nothing.
      drop_replaced_thumbnail(previous_thumbnail, saved)

      {:ok, saved}
    end
  end

  defp drop_replaced_thumbnail(nil, _saved), do: :ok

  defp drop_replaced_thumbnail(previous, saved) do
    case Storage.key_for(saved, :small) do
      ^previous -> :ok
      _replaced -> Storage.delete(previous)
    end
  end

  defp with_thumbnail(changes, nil), do: changes

  defp with_thumbnail(changes, %{name: name, size: size, content_type: content_type}) do
    Map.merge(changes, %{
      thumbnail_file_name: name,
      thumbnail_file_size: size,
      thumbnail_content_type: content_type
    })
  end

  @doc """
  Attaches uploads to a status, in the order given, and records that order on
  the status itself.

  Only the poster's own unattached uploads are accepted, and the whole thing is
  one transaction: a half-attached post would show some of its pictures and
  silently drop the rest.
  """
  @spec attach(Status.t(), [integer()]) :: {:ok, Status.t()} | {:error, term()}
  def attach(%Status{} = status, attachment_ids) do
    Repo.transaction(fn ->
      case attach_within(status, attachment_ids) do
        {:ok, attached} -> attached
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  The same, without a transaction of its own.

  For a caller that is already inside one — creating a post and hanging its
  pictures on it is one write, and a transaction inside a transaction only
  looks like a boundary.
  """
  @spec attach_within(Status.t(), [integer()]) ::
          {:ok, Status.t()} | {:error, :too_many_attachments | :unknown_attachment}
  def attach_within(%Status{} = status, attachment_ids) do
    # Duplicates first: the same id twice passes every check below and comes
    # back as the same picture rendered twice.
    attachment_ids = Enum.uniq(attachment_ids)

    # Checked here rather than only in the composer, so that no other path
    # can hang twenty pictures on one post: this is where attaching happens.
    if length(attachment_ids) > Abuuba.Instance.max_media_attachments() do
      {:error, :too_many_attachments}
    else
      claim(status, attachment_ids)
    end
  end

  defp claim(status, attachment_ids) do
    attachments = Enum.map(attachment_ids, &get_own_unattached(status.account_id, &1))

    if Enum.any?(attachments, &is_nil/1) do
      {:error, :unknown_attachment}
    else
      Enum.each(attachments, fn attachment ->
        attachment
        |> Ecto.Changeset.change(status_id: status.id)
        |> Repo.update!()
      end)

      {:ok,
       status
       |> Ecto.Changeset.change(ordered_media_attachment_ids: attachment_ids)
       |> Repo.update!()}
    end
  end

  @doc """
  The attachments of a status, in the order its author chose.

  The order comes from the status rather than from this table, so the query
  cannot supply it and sorting happens here.
  """
  @spec for_status(Status.t()) :: [Attachment.t()]
  def for_status(%Status{} = status) do
    by_id =
      Attachment
      |> where([a], a.status_id == ^status.id)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    # Fall back to id order for anything the status does not list, so an
    # attachment can never become invisible through a bookkeeping slip.
    listed = Enum.flat_map(status.ordered_media_attachment_ids, &List.wrap(by_id[&1]))
    rest = by_id |> Map.drop(status.ordered_media_attachment_ids) |> Map.values()

    listed ++ Enum.sort_by(rest, & &1.id)
  end

  @doc """
  An account's own unattached uploads, by id.

  One query rather than one per id: the composer redraws its strip on every
  keystroke, and four round trips a character is four too many.
  """
  @spec own_unattached(Account.t() | integer(), [integer()]) :: %{integer() => Attachment.t()}
  def own_unattached(account, ids)
  def own_unattached(_account, []), do: %{}
  def own_unattached(%Account{id: id}, ids), do: own_unattached(id, ids)

  def own_unattached(account_id, ids) do
    Attachment
    |> where([a], a.id in ^ids)
    |> where([a], a.account_id == ^account_id)
    |> where([a], is_nil(a.status_id))
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Removes an upload nobody posted, and its file.

  Only an unattached one. Deleting an attachment that is already on a post
  would leave the post pointing at a picture that is not there, and the copies
  other servers hold would still show it.
  """
  @spec delete_attachment(Attachment.t()) ::
          {:ok, Attachment.t()} | {:error, :already_posted | Ecto.Changeset.t()}
  def delete_attachment(%Attachment{status_id: id}) when not is_nil(id),
    do: {:error, :already_posted}

  def delete_attachment(%Attachment{} = attachment) do
    Upload.discard(attachment)

    Repo.delete(attachment)
  end

  @doc """
  Uploads that were never posted, or were orphaned when their status was
  deleted, and are older than `age` seconds. What the storage sweeper collects.
  """
  @spec unattached_before(DateTime.t()) :: [Attachment.t()]
  def unattached_before(%DateTime{} = cutoff) do
    Attachment
    |> where([a], is_nil(a.status_id))
    |> where([a], a.inserted_at < ^cutoff)
    |> order_by([a], asc: a.id)
    |> Repo.all()
  end

  @doc """
  Takes a file off a request and records it.

  A small image is finished inside the request, because making somebody poll
  for an ordinary photo turns one post into two round trips for no reason.
  Anything larger is queued, and that is what the v2 endpoint's 202 is telling
  the client.
  """
  @spec upload(Account.t(), map(), map()) ::
          {:ok, Attachment.t()} | {:error, atom() | Ecto.Changeset.t()}
  def upload(%Account{id: account_id}, file, attrs \\ %{}) do
    # The row is created first so the file can be named after the id the
    # database actually assigned. Naming it after one generated here would put
    # a file on disk that no attachment points at the moment the two disagree.
    with {:ok, attachment} <-
           create_attachment(%{
             account_id: account_id,
             description: Map.get(attrs, "description"),
             processing: :queued
           }),
         {:ok, stored} <- store_or_discard(file, attachment) do
      finish(attachment, stored, Upload.synchronous?(file))
    end
  end

  # A small picture is processed inside the request. Everything else is queued,
  # which is what the 202 tells the client. Either way it goes through the same
  # pipeline: a photograph that skipped it would reach a timeline with its
  # location metadata intact and no blurhash, and "it was under two megabytes"
  # is not a reason for that.
  defp finish(attachment, stored, immediate?) do
    with {:ok, saved} <-
           attachment
           |> Attachment.changeset(Map.put(stored, :processing, :queued))
           |> Repo.update() do
      if immediate? do
        process_now(saved)
      else
        ProcessingWorker.enqueue(saved.id)

        {:ok, saved}
      end
    end
  end

  defp process_now(attachment) do
    case Pipeline.run(attachment) do
      {:ok, processed} -> {:ok, processed}
      # Recorded as failed rather than raised: the upload endpoint answers with
      # an attachment whose state says so, which is what the client polls for
      # anyway.
      {:error, _reason} -> {:ok, get_attachment(attachment.id)}
    end
  end

  # A row with no file behind it is worse than no row: it would be listed as a
  # queued upload that never finishes.
  defp store_or_discard(file, attachment) do
    case Upload.store(file, attachment.id) do
      {:ok, stored} ->
        {:ok, stored}

      error ->
        Repo.delete(attachment)

        error
    end
  end

  @doc """
  Gives a video or an audio file a picture to stand in for it.

  Only while the upload is unattached, for the same reason a description is:
  changing it after the post went out changes it here and nowhere else, because
  the copies were already delivered.
  """
  @spec put_thumbnail(Attachment.t(), map()) ::
          {:ok, Attachment.t()} | {:error, :already_posted | atom() | Ecto.Changeset.t()}
  def put_thumbnail(%Attachment{status_id: id}, _file) when not is_nil(id),
    do: {:error, :already_posted}

  def put_thumbnail(%Attachment{} = attachment, file) do
    previous = Storage.key_for(attachment, :small)

    with {:ok, stored} <- Upload.store_thumbnail(file, attachment.id),
         {:ok, saved} <- attachment |> Attachment.changeset(stored) |> Repo.update() do
      # The new one is written and recorded first, and only then is the old one
      # taken away: the other order leaves the row pointing at a picture that is
      # no longer there, which is worse than a file nobody points at. The key
      # carries a random filename, so a replacement lands beside its
      # predecessor rather than over it, and nothing would ever find the one it
      # replaced -- the row that named it now names the new one.
      new_key = Storage.key_for(saved, :small)

      if is_binary(previous) and previous != new_key, do: Storage.delete(previous)

      {:ok, saved}
    end
  end

  @doc """
  Changes what an upload says about itself.

  Only while it is unattached. A description edited after the post went out
  would be a description other servers never see, so the post is the place to
  change it once it exists.
  """
  @spec update_upload(Attachment.t(), map()) ::
          {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()}
  def update_upload(%Attachment{} = attachment, attrs) do
    attachment
    |> Attachment.description_changeset(normalise_upload_attrs(attachment, attrs))
    |> Repo.update()
  end

  @doc """
  Changes what a picture already on a post says about itself.

  The other half of `update_upload/2`, whose own note says the post is the
  place to change a description once it exists -- and which nothing did, so a
  typo in alt text could not be fixed after posting. An edit is what carries
  the correction to the other servers holding a copy.

  Only attachments on this post: an id belonging to somebody else's, or to an
  upload nobody has posted, is skipped rather than refused, because a client
  sending a stale id should not lose the edit it was making.
  """
  @spec update_on_status(Status.t(), [map()]) :: :ok
  def update_on_status(%Status{} = status, attributes) when is_list(attributes) do
    mine =
      Attachment
      |> where([a], a.status_id == ^status.id)
      |> Repo.all()
      |> Map.new(&{to_string(&1.id), &1})

    Enum.each(attributes, fn attrs ->
      case Map.get(mine, to_string(attrs["id"])) do
        nil -> :ok
        attachment -> update_upload(attachment, attrs)
      end
    end)

    :ok
  end

  def update_on_status(%Status{}, _attributes), do: :ok

  @doc """
  Forgets an upload nobody has posted yet.
  """
  @spec delete_upload(Attachment.t()) ::
          {:ok, Attachment.t()} | {:error, :already_attached}
  def delete_upload(%Attachment{status_id: nil} = attachment), do: Repo.delete(attachment)
  def delete_upload(%Attachment{}), do: {:error, :already_attached}

  # Merged into what is already there rather than replacing it. The meta map
  # also holds the original file's size and name, and a focal point that wiped
  # those would lose them for good.
  defp normalise_upload_attrs(attachment, attrs) do
    attrs
    |> Map.take(~w(description focus))
    |> Map.new(fn
      {"focus", value} ->
        {:meta, Map.put(attachment.meta || %{}, "focus", parse_focus(value))}

      {key, value} ->
        {String.to_existing_atom(key), value}
    end)
  end

  # "x,y", each between -1 and 1, which is where a client says the interesting
  # part of a picture is so a crop keeps a face rather than an elbow.
  defp parse_focus(value) when is_binary(value) do
    case String.split(value, ",") do
      [x, y] -> %{"x" => clamp(x), "y" => clamp(y)}
      _ -> %{"x" => 0.0, "y" => 0.0}
    end
  end

  defp parse_focus(_value), do: %{"x" => 0.0, "y" => 0.0}

  defp clamp(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number |> max(-1.0) |> min(1.0)
      :error -> 0.0
    end
  end
end

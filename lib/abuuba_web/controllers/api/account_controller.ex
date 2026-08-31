defmodule AbuubaWeb.API.AccountController do
  @moduledoc """
  `/api/v1/accounts`.

  ## Relationships come back from every action

  Following, blocking, muting and their opposites all answer with the
  relationship rather than with the account or with nothing. A client turns a
  button into its new state from that answer, so an endpoint that returned
  something else would leave the button showing what was true a moment ago.

  ## A stranger's account is not hidden

  Looking somebody up works without a token. Which of their posts you can read
  is a separate question, answered where the posts are.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Lists
  alias Abuuba.Media.ProfileImages
  alias Abuuba.Moderation.Signup.Captcha
  alias Abuuba.OAuth
  alias Abuuba.OAuth.Scopes
  alias Abuuba.Relationships
  alias Abuuba.Roles
  alias Abuuba.Search
  alias Abuuba.Statuses
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.NestedParams
  alias AbuubaWeb.API.Pagination
  alias AbuubaWeb.ClientIP

  plug AbuubaWeb.Plugs.RequireClientCredentials when action in [:create]
  # The reference implementation's cap, and its status code for exceeding it.
  @batch_limit 40

  plug AbuubaWeb.Plugs.RequireUser
       when action in [
              :verify_credentials,
              :update_credentials,
              :relationships,
              :familiar_followers,
              :follow,
              :unfollow,
              :block,
              :unblock,
              :mute,
              :unmute,
              :note,
              :remove_from_followers,
              :profile,
              :update_profile,
              :remove_picture,
              :endorse,
              :unendorse,
              :lists
            ]

  # `create` writes on nobody's behalf, so the token's own scopes are the only
  # thing standing between a read-only app and a table full of accounts.
  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:accounts"]
       when action in [
              :create,
              :update_credentials,
              :update_profile,
              :remove_picture,
              # Somebody's private note about another account, and featuring an
              # account on their own profile. Both are edits to the reader's own
              # account rather than to the relationship, which is where the
              # reference implementation files them too.
              :note,
              :endorse,
              :unendorse
            ]

  # `profile` exists so an app can ask for a name and a picture and nothing
  # else, so a token carrying it satisfies these without also carrying a read
  # scope over everything.
  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["profile", "read:accounts"]} when action in [:verify_credentials, :profile]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:follows"] when action in [:follow, :unfollow, :remove_from_followers]

  plug AbuubaWeb.Plugs.RequireScopes, ["write:blocks"] when action in [:block, :unblock]
  plug AbuubaWeb.Plugs.RequireScopes, ["write:mutes"] when action in [:mute, :unmute]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["read:follows"] when action in [:relationships, :familiar_followers]

  plug AbuubaWeb.Plugs.RequireScopes, ["read:lists"] when action in [:lists]

  # These answer a stranger too, but a token widens what comes back: a follower
  # sees posts a stranger does not. So the scope conditions the token rather
  # than the request.
  plug AbuubaWeb.Plugs.RequireScopes,
       {:when_authenticated, ["read:accounts"]}
       when action in [:index, :show, :lookup, :search, :statuses, :followers, :following]

  @doc """
  Signs somebody up, on behalf of the application asking.

  The app has no person to act for yet, so this is the one endpoint that wants
  a client-credentials token rather than a user's. What comes back is an access
  token for the account just made, so the app can carry straight on rather than
  sending somebody through a browser to log in to an account they have this
  second created.

  A token comes back even when the server moderates its sign-ups and the
  account is therefore not usable yet. That is the reference implementation's
  behaviour and clients depend on it: the token is what lets the app poll
  `verify_credentials` and show "still waiting" rather than an error it cannot
  explain.
  """
  def create(conn, params) do
    with :ok <- Captcha.verify(params["captcha_solution"] || params["h-captcha-response"]),
         {:ok, %{user: user}} <-
           Auth.register(registration_params(params),
             ip: ClientIP.of(conn),
             application_id: conn.assigns.current_token.application_id
           ) do
      token_source = conn.assigns.current_token
      scopes = Scopes.parse!(token_source.scopes)

      {:ok, token, raw} = OAuth.issue_token(token_source.application, user, scopes)

      Auth.deliver_signup_mail(user, &url(~p"/confirm/#{&1}"))

      json(conn, %{
        access_token: raw,
        token_type: "Bearer",
        scope: token.scopes,
        created_at: DateTime.to_unix(token.inserted_at)
      })
    else
      # 403 rather than 422: nothing about the form was wrong, and a client
      # that showed field errors here would be pointing at the wrong thing.
      {:error, reason} when reason in [:registration_closed, :invalid_invite] ->
        API.error(conn, 403, "Registration is currently not allowed")

      {:error, %Ecto.Changeset{} = changeset} ->
        API.error(conn, 422, "Validation failed", signup_errors(changeset))

      {:error, captcha_reason} ->
        API.error(conn, 422, captcha_message(captcha_reason))
    end
  end

  @doc """
  Several accounts at once, by id.

  For a client that has just been handed a page of ids — the people in a
  conversation, the accounts in a list — and would otherwise ask for each of
  them separately.

  An id nobody answers to is skipped rather than refused: a client holding a
  stale id wants the rest of the page, not an error about one of them.
  """
  def index(conn, params) do
    ids = API.id_list(params, "id")

    if length(ids) > @batch_limit do
      API.error(conn, 422, "Validation failed")
    else
      viewer = current_account(conn)

      json(conn, Entities.accounts(Accounts.visible_by_ids(ids), viewer))
    end
  end

  @doc """
  Who the token belongs to.
  """
  def verify_credentials(conn, _params) do
    account = current_account(conn)

    conn
    |> json(
      account
      |> Entities.account(account)
      |> Map.put("source", Entities.account_source(account))
      # Clients hide admin surfaces they cannot use, and this is where they
      # find out. Absent rather than null for somebody with no role, which is
      # what the reference implementation sends.
      |> put_role(current_user(conn))
    )
  end

  @doc """
  Changes what somebody says about themselves.

  `profile_changeset/2` rather than `changeset/2`: these parameters came from
  the account's owner, and the trusted changeset would let them set their own
  moderation state and their own federation endpoints.
  """
  def update_credentials(conn, params) do
    case save_profile(current_account(conn), params) do
      {:ok, updated} ->
        json(
          conn,
          updated
          |> Entities.account(updated)
          |> Map.put("source", Entities.account_source(updated))
        )

      {:error, changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  @doc """
  The profile its owner is editing.

  Not `verify_credentials/2` with different fields: that answers "who am I",
  this answers "what is in my edit boxes", and the two diverge as soon as one
  carries the raw text of a note that the other renders.
  """
  def profile(conn, _params) do
    json(conn, Entities.profile(current_account(conn)))
  end

  @doc """
  Saves it.
  """
  def update_profile(conn, params) do
    case save_profile(current_account(conn), params) do
      {:ok, updated} ->
        json(conn, Entities.profile(updated))

      {:error, changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  @doc """
  Takes a picture off a profile.

  The files go with the row. A picture nothing points at is rubbish on disk,
  and somebody removing their avatar has asked for it to be gone rather than
  merely hidden.
  """
  def remove_picture(conn, %{"kind" => kind}) when kind not in ["avatar", "header"],
    do: API.error(conn, 404, "Record not found")

  def remove_picture(conn, %{"kind" => kind}) do
    account = current_account(conn)
    attrs = ProfileImages.remove(account, String.to_existing_atom(kind))

    case Accounts.update_account(account, attrs) do
      {:ok, updated} ->
        json(conn, Entities.profile(updated))

      {:error, changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  @doc """
  One account.
  """
  def show(conn, %{"id" => id}) do
    with_account(conn, id, fn account, viewer -> json(conn, Entities.account(account, viewer)) end)
  end

  @doc """
  Finding somebody by the handle a person typed.
  """
  def lookup(conn, params) do
    case Accounts.lookup(params["acct"]) do
      nil -> API.error(conn, 404, "Record not found")
      account -> json(conn, Entities.account(account, current_account(conn)))
    end
  end

  @doc """
  Half-typed names, for a mention box.
  """
  def search(conn, params) do
    viewer = current_account(conn)

    # `following` narrows to the people this reader follows, which is what
    # `followed_by` does and what the same parameter has always done on
    # `/api/v2/search`. It was mapped to "local accounts only" instead, so the
    # answer kept people the reader does not follow and dropped the remote ones
    # they do -- one question, two surfaces, two answers.
    #
    # `resolve` is read by the v2 endpoint, which fetches a handle nobody here
    # holds yet. It cannot be read here: this route answers without a token, so
    # honouring it would let a stranger make this server fetch whatever handle
    # they name. Mapping it to "local only" was not a substitute for that -- it
    # hid every remote account this server already knows.
    followed_by = if API.boolean(params["following"], false) and viewer, do: viewer.id

    accounts =
      Search.accounts(params["q"], viewer,
        limit: API.limit(params, 40, 80),
        followed_by: followed_by
      )

    json(conn, Entities.accounts(accounts, viewer))
  end

  @doc """
  What this account's relationship is to each of several others.
  """
  def relationships(conn, params) do
    account = current_account(conn)

    ids = params |> API.id_list("id") |> Enum.take(40)

    json(
      conn,
      account.id |> Relationships.relationships(ids) |> Enum.map(&Entities.relationship/1)
    )
  end

  @doc """
  Who that you follow also follows these people.
  """
  def familiar_followers(conn, params) do
    account = current_account(conn)

    ids = params |> API.id_list("id") |> Enum.take(20)

    answers =
      account
      |> Relationships.familiar_followers(ids)
      |> Enum.map(fn {id, accounts} ->
        %{"id" => API.id(id), "accounts" => Entities.accounts(accounts, account)}
      end)

    json(conn, answers)
  end

  ## An account's own things

  def statuses(conn, %{"id" => id} = params) do
    with_account(conn, id, fn account, viewer ->
      page =
        params
        |> Pagination.params(default: 20, max: 40)
        |> Map.merge(timeline_filters(params))

      statuses = account_statuses(account, viewer, params, page)

      conn
      |> Pagination.put_link_header(statuses)
      |> json(Entities.statuses(statuses, viewer, filter_context: "account"))
    end)
  end

  # The filters an app asks for, which this endpoint used to accept and drop.
  # `Pagination.params/2` answers only with cursors and a limit, so everything
  # else has to be put back -- and `Statuses.account_timeline/3` has always
  # known what to do with these. The profile page and the feed were passing
  # them all along, which is why the web interface was right and every
  # third-party client was wrong.
  defp timeline_filters(params) do
    %{
      exclude_replies: API.truthy?(params["exclude_replies"]),
      exclude_reblogs: API.truthy?(params["exclude_reblogs"]),
      only_media: API.truthy?(params["only_media"]),
      tagged: presence(params["tagged"])
    }
  end

  # A pinned page is a different list rather than a filter on this one: it is
  # ordered by when each was pinned, not by when it was written, and it does
  # not paginate the way the timeline does.
  defp account_statuses(account, viewer, params, page) do
    if API.truthy?(params["pinned"]) do
      Statuses.pinned(account, viewer)
    else
      Statuses.account_timeline(account, viewer, page)
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil

  def followers(conn, %{"id" => id} = params) do
    with_collection(conn, id, params, &Relationships.followers/3)
  end

  def following(conn, %{"id" => id} = params) do
    with_collection(conn, id, params, &Relationships.following/3)
  end

  # The web profile has honoured `hide_collections` since it was written and
  # the ActivityPub endpoints honour it too; these two did not, so the one
  # setting that says "do not show who I know" worked everywhere except in an
  # app. The blocked case is the same shape: a profile that answers the person
  # it blocked has not blocked them.
  defp with_collection(conn, id, params, list) do
    with_account(conn, id, fn account, viewer ->
      if Relationships.collections_visible?(account, viewer) do
        collection(conn, viewer, list.(account, viewer, Pagination.params(params)))
      else
        json(conn, [])
      end
    end)
  end

  ## Acting on somebody

  def follow(conn, %{"id" => id} = params) do
    acting_on(conn, id, fn account, target ->
      attrs =
        %{}
        |> put_if(params, "reblogs", :show_reblogs)
        |> put_if(params, "notify", :notify)
        |> put_languages(params)

      # A follow request spends the allowance too: asking four hundred locked
      # accounts in a day is the same list-building the number exists to stop.
      result =
        with :ok <- Relationships.take_follow_budget(account),
             do: Relationships.follow_or_request(account, target, attrs)

      case result do
        {:ok, _edge} ->
          render_relationship(conn, account, target)

        {:error, :rate_limited} ->
          API.error(conn, 429, "Too many requests")

        {:error, changeset} ->
          API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
      end
    end)
  end

  def unfollow(conn, %{"id" => id}) do
    acting_on(conn, id, fn account, target ->
      Relationships.unfollow(account, target)

      render_relationship(conn, account, target)
    end)
  end

  def block(conn, %{"id" => id}) do
    acting_on(conn, id, fn account, target ->
      {:ok, _} = Relationships.block(account, target)

      render_relationship(conn, account, target)
    end)
  end

  def unblock(conn, %{"id" => id}) do
    acting_on(conn, id, fn account, target ->
      Relationships.unblock(account, target)

      render_relationship(conn, account, target)
    end)
  end

  def mute(conn, %{"id" => id} = params) do
    acting_on(conn, id, fn account, target ->
      # Absent means the whole mute, and `notifications=false` arrives as the
      # string from anything form-encoded -- which `!= false` read as "yes,
      # hide them", the opposite of what was asked, while answering `true` and
      # sounding certain about it.
      attrs =
        %{hide_notifications: API.boolean(params["notifications"], true)}
        |> put_expiry(params["duration"])

      {:ok, _} = Relationships.mute(account, target, attrs)

      render_relationship(conn, account, target)
    end)
  end

  def unmute(conn, %{"id" => id}) do
    acting_on(conn, id, fn account, target ->
      Relationships.unmute(account, target)

      render_relationship(conn, account, target)
    end)
  end

  @doc """
  A private note about somebody, visible only to whoever wrote it.
  """
  def note(conn, %{"id" => id} = params) do
    acting_on(conn, id, fn account, target ->
      {:ok, _} = Relationships.put_note(account, target, params["comment"] || "")

      render_relationship(conn, account, target)
    end)
  end

  def remove_from_followers(conn, %{"id" => id}) do
    acting_on(conn, id, fn account, target ->
      :ok = Relationships.remove_follower(account, target)

      render_relationship(conn, account, target)
    end)
  end

  @doc """
  The hashtags on somebody's profile.
  """
  def featured_tags(conn, %{"id" => id}) do
    with_account(conn, id, fn account, _viewer -> json(conn, Entities.featured_tags(account)) end)
  end

  @doc """
  Who somebody has put on their profile as worth following.
  """
  def endorsements(conn, %{"id" => id} = params) do
    with_account(conn, id, fn account, viewer ->
      endorsed =
        Relationships.endorsements(account, Pagination.params(params, default: 40, max: 80))

      collection(conn, viewer, endorsed)
    end)
  end

  @doc """
  Puts somebody on the reader's own profile as worth following.
  """
  def endorse(conn, %{"id" => id}) do
    acting_on(conn, id, fn account, target ->
      case Relationships.endorse(account, target) do
        :ok ->
          render_relationship(conn, account, target)

        {:error, :not_following} ->
          API.error(conn, 422, "Validation failed: you have to follow somebody to endorse them")
      end
    end)
  end

  @doc """
  Takes them back off it.
  """
  def unendorse(conn, %{"id" => id}) do
    acting_on(conn, id, fn account, target ->
      :ok = Relationships.unendorse(account, target)

      render_relationship(conn, account, target)
    end)
  end

  @doc """
  Which of the reader's own lists somebody is in.

  The reader's lists, not theirs. Whose lists somebody appears in is nobody
  else's business, and answering with the asker's own is the only reading of
  the question that does not publish that.
  """
  def lists(conn, %{"id" => id}) do
    with_account(conn, id, fn account, viewer ->
      json(conn, Enum.map(Lists.containing(viewer, account), &Entities.list/1))
    end)
  end

  @doc """
  Cryptographic identity proofs, which this server does not do.

  An empty array rather than a 404, because that is what the reference
  implementation answers and a client that got a 404 would show an error where
  it meant to show nothing. Keybase was the only thing that ever filled it.
  """
  def identity_proofs(conn, %{"id" => id}) do
    with_account(conn, id, fn _account, _viewer -> json(conn, []) end)
  end

  ## Plumbing

  defp collection(conn, viewer, accounts) do
    conn
    |> Pagination.put_link_header(accounts)
    |> json(Entities.accounts(accounts, viewer))
  end

  ## Signing up

  # The reference implementation's parameter names, mapped onto ours. `reason`
  # is the few words a moderated server asks a stranger for; `agreement` is the
  # rules checkbox, and it is always required here, because an app cannot show
  # somebody the rules and then decide on their behalf that they were read.
  defp registration_params(params) do
    %{
      "username" => params["username"],
      "email" => params["email"],
      "password" => params["password"],
      "agreement" => params["agreement"],
      "locale" => params["locale"],
      "invite_code" => params["invite_code"],
      "invite_reason" => params["reason"]
    }
  end

  # Reported under the name the client sent, not the name the column has. A
  # client that rendered a box called `reason` has to be able to find the error
  # about it; the reference implementation renames the same field for the same
  # reason.
  defp signup_errors(changeset) do
    changeset
    |> Entities.field_errors()
    |> rename_error(:invite_reason, :reason)
  end

  defp rename_error(errors, from, to) do
    case Map.pop(errors, from) do
      {nil, errors} -> errors
      {value, errors} -> Map.put(errors, to, value)
    end
  end

  # A puzzle is off unless an admin configured one, so this costs nothing on
  # the ordinary server. Where one is on, an app has to carry the answer
  # through: a check that cannot be made must not pass, or the puzzle is
  # decoration that anybody can walk around by using the API instead.
  defp captcha_message(:captcha_missing),
    do: "This server needs a puzzle answer to sign anybody up"

  defp captcha_message(:captcha_unavailable), do: "The puzzle could not be checked just now"
  defp captcha_message(_reason), do: "That puzzle answer was not accepted"

  defp with_account(conn, id, fun) do
    viewer = current_account(conn)

    case Accounts.get_account(API.parse_id(id) || 0) do
      %Account{suspended_at: nil} = account -> fun.(account, viewer)
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  # Acting on yourself is refused rather than quietly done: following or
  # blocking yourself is a client bug, and a relationship that reported it as
  # having worked would leave the button in a state nothing can undo.
  defp acting_on(conn, id, fun) do
    with_account(conn, id, fn target, account ->
      if account.id == target.id do
        API.error(conn, 422, "Validation failed: you cannot do that to yourself")
      else
        fun.(account, target)
      end
    end)
  end

  defp render_relationship(conn, account, target) do
    json(conn, Entities.relationship(Relationships.relationship(account, target)))
  end

  # Two writes with two different levels of trust, on purpose. What somebody
  # typed goes through `update_profile/2`, which can only reach the columns an
  # account's owner may set. The picture columns are deliberately not among
  # them: a client that could set `avatar_file_name` itself would be able to
  # point its avatar at any file this server has ever stored. Those are written
  # by `update_account/2`, from a picture we stored ourselves a moment earlier.
  defp save_profile(account, params) do
    pictures = picture_params(params, account)

    with {:ok, updated} <- Accounts.update_profile(account, editable_params(params)) do
      if pictures == %{}, do: {:ok, updated}, else: Accounts.update_account(updated, pictures)
    end
  end

  defp editable_params(params) do
    params
    |> Map.take(~w(display_name note locked bot discoverable indexable hide_collections))
    |> Map.merge(fields_param(params))
    |> Map.merge(attribution_domains_param(params))
  end

  # A list, and a form sends one as `attribution_domains[]`. Absent means "not
  # mentioned" rather than "empty", so the key is only added when it was sent:
  # merging an empty list for every unrelated profile save would silently clear
  # somebody's attributions the first time they changed their display name.
  defp attribution_domains_param(params) do
    case Map.fetch(params, "attribution_domains") do
      {:ok, domains} when is_list(domains) -> %{"attribution_domains" => domains}
      {:ok, domain} when is_binary(domain) -> %{"attribution_domains" => String.split(domain)}
      :error -> %{}
      _not_a_list -> %{}
    end
  end

  # An avatar and a header arrive as ordinary multipart uploads. Stored before
  # the row is written, so a failure to store leaves the account pointing at
  # the picture it already had rather than at nothing.
  defp picture_params(params, account) do
    Enum.reduce(ProfileImages.kinds(), %{}, fn kind, attrs ->
      params
      |> Map.get(to_string(kind))
      |> stored_picture(account, kind)
      |> Map.merge(attrs)
    end)
  end

  defp stored_picture(%Plug.Upload{} = upload, account, kind) do
    case ProfileImages.store(account, kind, upload) do
      {:ok, stored} -> stringify(stored)
      # Left as it was rather than blanked. A picture that could not be stored
      # is a failed change, not a request to remove the one already there.
      {:error, _reason} -> %{}
    end
  end

  defp stored_picture(_value, _account, _kind), do: %{}

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp fields_param(%{"fields_attributes" => fields}) when is_map(fields) or is_list(fields) do
    %{"fields" => NestedParams.list(fields)}
  end

  defp fields_param(_params), do: %{}

  defp put_if(attrs, params, key, field) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(attrs, field, API.truthy?(value))
      :error -> attrs
    end
  end

  defp put_languages(attrs, %{"languages" => languages}) when is_list(languages) do
    Map.put(attrs, :languages, Enum.filter(languages, &is_binary/1))
  end

  defp put_languages(attrs, _params), do: attrs

  defp put_expiry(attrs, duration) when is_binary(duration) do
    case Integer.parse(duration) do
      {seconds, _rest} when seconds > 0 -> expiry(attrs, seconds)
      _ -> attrs
    end
  end

  defp put_expiry(attrs, duration) when is_integer(duration) and duration > 0,
    do: expiry(attrs, duration)

  defp put_expiry(attrs, _duration), do: attrs

  defp expiry(attrs, seconds) do
    Map.put(attrs, :expires_at, DateTime.add(DateTime.utc_now(), seconds, :second))
  end

  defp put_role(payload, user) do
    case Entities.role(Roles.of(user)) do
      nil -> payload
      role -> Map.put(payload, "role", role)
    end
  end
end

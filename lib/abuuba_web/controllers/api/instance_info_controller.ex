defmodule AbuubaWeb.API.InstanceInfoController do
  @moduledoc """
  The informational endpoints hanging off the instance: emoji, announcements,
  preferences, peers, rules, trends and the tag relationships.

  Several of these answer with an empty list rather than a 404 while what they
  describe does not exist yet. That is deliberate: a client that gets a 404
  shows an error where it meant to show nothing, and "this server has no
  trends" is a true answer while "there is no such endpoint" is not.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts.PostingDefaults
  alias Abuuba.Accounts.Preferences
  alias Abuuba.I18n
  alias Abuuba.Instance
  alias Abuuba.Moderation.Domains
  alias Abuuba.Relationships
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Translation
  alias Abuuba.Trends
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser
       when action in [
              :preferences,
              :dismiss_announcement,
              :react,
              :unreact,
              :followed_tags,
              :follow_tag,
              :unfollow_tag,
              :feature_tag,
              :unfeature_tag,
              :domain_block_preview
            ]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:accounts"]
       when action in [:dismiss_announcement, :react, :unreact, :feature_tag, :unfeature_tag]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:follows"] when action in [:follow_tag, :unfollow_tag]

  plug AbuubaWeb.Plugs.RequireScopes, ["read:follows"] when action in [:followed_tags]

  # Somebody's own settings and their own list of blocked servers. Both are
  # things about them and not about this server, so both want a read scope.
  plug AbuubaWeb.Plugs.RequireScopes,
       ["read:accounts"] when action in [:preferences, :domain_block_preview]

  def custom_emojis(conn, _params) do
    json(conn, Enum.map(Instance.offered_custom_emojis(), &Entities.custom_emoji/1))
  end

  @doc """
  What a client should default to when composing.

  Read off the account rather than invented, so that a client opening a compose
  box picks the same visibility the person last chose here rather than the
  client's own default.
  """
  def preferences(conn, _params) do
    account = current_account(conn)
    user = current_user(conn)

    # Every posting key here was a constant. Somebody who had set their posts
    # to followers-only was told "public" by every app that asked, while the
    # compose box in this server's own interface read the stored value and got
    # it right -- one setting, two surfaces, and the disagreement pointing the
    # wrong way: a client that believes "public" is how something meant for
    # followers goes out to everybody.
    posting = PostingDefaults.for_user(user)
    reading = Preferences.for_user(user)

    json(conn, %{
      "posting:default:visibility" => posting["visibility"],
      "posting:default:sensitive" => posting["sensitive"],
      "posting:default:language" => posting["language"],
      "posting:default:quote_policy" => posting["quote_policy"],
      # Stored as the thing somebody switches on, reported as the thing they
      # get. The two keys mean opposite things and both spellings are right
      # for their own side.
      "reading:autoplay:gifs" => not reading["disable_autoplay"],
      # No setting behind these two yet, so the built-in answer is the honest
      # one: `default` means the client decides, which is what happens.
      "reading:expand:media" => "default",
      "reading:expand:spoilers" => false,
      "reading:hide:collections" => account.hide_collections
    })
  end

  ## Announcements

  def announcements(conn, _params) do
    viewer = current_account(conn)

    json(
      conn,
      Instance.announcements()
      |> Enum.reject(&Instance.announcement_read?(&1, viewer))
      |> Enum.map(&Entities.announcement(&1, viewer))
    )
  end

  def dismiss_announcement(conn, %{"id" => id}) do
    with_announcement(conn, id, fn announcement ->
      :ok = Instance.dismiss_announcement(announcement, current_account(conn))

      json(conn, %{})
    end)
  end

  def react(conn, %{"id" => id, "name" => name}) do
    with_announcement(conn, id, fn announcement ->
      :ok = Instance.react_to_announcement(announcement, current_account(conn), name)

      json(conn, %{})
    end)
  end

  def unreact(conn, %{"id" => id, "name" => name}) do
    with_announcement(conn, id, fn announcement ->
      :ok = Instance.unreact_to_announcement(announcement, current_account(conn), name)

      json(conn, %{})
    end)
  end

  ## Instance sub-resources

  @doc """
  Every server this one has heard from, by name.

  Names only. It is a map of who talks to whom, and saying more about a peer
  than that it exists would publish something about our own users' reach that
  they never agreed to.
  """
  def peers(conn, _params), do: json(conn, Instance.peers())

  def rules(conn, _params) do
    # In the reader's language where somebody has translated it. A rule shown
    # in a language the reader cannot read is a rule they did not agree to.
    json(conn, Enum.map(Settings.rules(locale(conn)), &Entities.rule/1))
  end

  defp locale(conn), do: conn.assigns[:locale] || Gettext.get_locale(AbuubaWeb.Gettext)

  def extended_description(conn, _params) do
    json(conn, %{
      "updated_at" => Settings.updated_at("extended_description"),
      "content" => Settings.get("extended_description") || ""
    })
  end

  @doc """
  Numbers about this server's own activity: twelve weeks of posts, sign-ins
  and registrations, which the server-comparison crawlers chart.

  404 in limited federation mode, as the reference implementation answers: a
  server that talks only to its allowlist is not publishing its vital signs
  to strangers.
  """
  def activity(conn, _params) do
    if Domains.limited_federation?() do
      API.error(conn, 404, "Record not found")
    else
      json(conn, Instance.activity())
    end
  end

  @doc """
  Which domains this server refuses, for whoever the admin decided may ask.

  Off by default, as the reference implementation ships: the list is a record
  of moderation decisions, and naming the servers a moderator acted against
  invites their users to come and argue about it. When it is served, an empty
  list is served rather than a 404 -- "we block nobody" is a true and useful
  answer. When it is not, the 404 means "this server does not say", and a
  stranger under the `users` setting gets the same 404 rather than a 401,
  which would announce that there is something being withheld.
  """
  def domain_blocks(conn, _params) do
    if Settings.domain_blocks_visible?(current_account(conn)) do
      json(conn, Domains.public_blocks())
    else
      API.error(conn, 404, "Record not found")
    end
  end

  def translation_languages(conn, _params), do: json(conn, Translation.languages())

  @doc """
  The privacy policy, as a document rather than a page.

  Same shape as the extended description and the terms: `updated_at` and the
  text. A single document rather than a versioned series, because unlike the
  terms nobody has to be told when it changes for the change to take effect.
  """
  def privacy_policy(conn, _params) do
    json(conn, %{
      "updated_at" => Settings.get("privacy_effective_on"),
      "content" => Settings.get("privacy_text") || ""
    })
  end

  @doc """
  The languages this server's own interface speaks.

  Not the languages people post in, which is every language there is. A client
  offering a language picker for the interface asks this.
  """
  def languages(conn, _params) do
    json(conn, Enum.map(I18n.known_locales(), &%{"code" => &1, "name" => I18n.language_name(&1)}))
  end

  @doc """
  Domains this server knows of whose name begins with what was typed.

  For the box a client offers when somebody is about to block a whole server,
  so they are typing against a list rather than from memory. Only what this
  server has actually federated with; it is not a directory of the network.
  """
  def peers_search(conn, params) do
    json(conn, Instance.peers_starting_with(params["q"], limit: 10))
  end

  @doc """
  What blocking a whole domain would cost the reader.

  Answered before the block rather than after, because the numbers are the
  whole of the decision: somebody who follows nobody there will block without
  thinking, and somebody with forty follows there deserves to be asked twice.
  """
  def domain_block_preview(conn, params) do
    account = current_account(conn)
    domain = to_string(params["domain"]) |> String.trim() |> String.downcase()

    json(conn, %{
      "following_count" => Relationships.following_on_domain(account, domain),
      "followers_count" => Relationships.followers_on_domain(account, domain)
    })
  end

  def terms_of_service(conn, params) do
    case terms(params["date"]) do
      nil -> API.error(conn, 404, "Record not found")
      terms -> json(conn, Entities.terms_of_service(terms))
    end
  end

  defp terms(nil), do: Instance.current_terms()

  defp terms(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> Instance.terms_for(date)
      _ -> nil
    end
  end

  ## Trends

  def trending_tags(conn, params) do
    viewer = current_account(conn)

    json(conn, Entities.tags(Trends.tags(viewer, trend_opts(params)), viewer))
  end

  def trending_statuses(conn, params) do
    viewer = current_account(conn)

    # One rendering batch. Rendering each status alone ran the whole
    # per-page query set once per trending post.
    json(conn, Entities.statuses(Trends.statuses(viewer, trend_opts(params)), viewer))
  end

  def trending_links(conn, params) do
    links = Trends.trending_links(current_account(conn), trend_opts(params))

    json(conn, Entities.trend_links(links))
  end

  defp trend_opts(params) do
    [limit: API.limit(params, 10, 40)]
    |> then(fn opts ->
      case params["language"] do
        language when is_binary(language) and language != "" -> [{:language, language} | opts]
        _ -> opts
      end
    end)
  end

  ## Tags

  def show_tag(conn, %{"id" => name}) do
    with_tag(conn, name, fn tag -> json(conn, Entities.tag(tag, current_account(conn))) end)
  end

  def followed_tags(conn, params) do
    account = current_account(conn)
    tags = Statuses.followed_tags(account, %{limit: API.limit(params, 100, 200)})

    json(conn, Entities.tags(tags, account))
  end

  def follow_tag(conn, %{"id" => name}) do
    account = current_account(conn)

    with_tag(conn, name, fn tag ->
      :ok = Statuses.follow_tag(account, tag)

      json(conn, Entities.tag(tag, account))
    end)
  end

  def unfollow_tag(conn, %{"id" => name}) do
    account = current_account(conn)

    with_tag(conn, name, fn tag ->
      :ok = Statuses.unfollow_tag(account, tag)

      json(conn, Entities.tag(tag, account))
    end)
  end

  @doc """
  Puts a tag on the reader's own profile.

  The same act as `POST /api/v1/featured_tags`, reached by name rather than by
  making a row and getting an id back. Clients use whichever they have to hand,
  so both exist and both answer with what the client asked about: this one the
  tag, the other one the featured row.
  """
  def feature_tag(conn, %{"id" => name}) do
    account = current_account(conn)

    case Statuses.feature_tag_by_name(account, name) do
      {:ok, tag} ->
        json(conn, Entities.tag(tag, account))

      {:error, :too_many} ->
        API.error(conn, 422, "Validation failed: you cannot feature any more hashtags")

      {:error, changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  @doc """
  Takes it back off.
  """
  def unfeature_tag(conn, %{"id" => name}) do
    account = current_account(conn)

    with_tag(conn, name, fn tag ->
      :ok = Statuses.unfeature_tag(account, tag)

      json(conn, Entities.tag(tag, account))
    end)
  end

  defp with_tag(conn, name, fun) do
    case Statuses.get_tag(name) do
      nil -> API.error(conn, 404, "Record not found")
      tag -> fun.(tag)
    end
  end

  defp with_announcement(conn, id, fun) do
    case Instance.get_announcement(API.id_param(%{"id" => id}, "id")) do
      nil -> API.error(conn, 404, "Record not found")
      announcement -> fun.(announcement)
    end
  end
end

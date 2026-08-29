defmodule AbuubaWeb.FeedController do
  @moduledoc """
  RSS for a profile and for a hashtag.

  ## Why RSS at all

  Somebody who wants to read one person, or one subject, without an account
  anywhere. A feed reader is the oldest answer to that and it still works, and
  it costs this server one query and no session.

  ## What is in one

  Public posts only, and never a boost. A feed is a list of things somebody
  wrote, and a reader that filled up with other people's posts because
  somebody had a busy afternoon of boosting would be unsubscribed from within
  the week. Unlisted posts are out too: unlisted means "not in the lists this
  server publishes", and a feed is one of those lists.

  ## Content, not summary

  The post's HTML goes in `content:encoded`, and the plain text in
  `description`. A reader that understands neither still shows something, and
  one that understands both shows the post as written. A content warning
  becomes the title, so a feed reader's list view carries the warning rather
  than the thing it was warning about.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Serializer
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Timelines

  @limit 20

  @doc """
  One account's public posts.
  """
  def account(conn, %{"username" => username}) do
    case Accounts.lookup(username) do
      %Account{suspended_at: nil, domain: nil} = subject ->
        statuses = Statuses.account_timeline(subject, nil, feed_params())

        conn
        |> render_feed(
          title: display_name(subject) <> " (@" <> subject.username <> ")",
          description: summary(subject.note),
          link: url(~p"/@#{subject.username}"),
          self: url(~p"/@#{subject.username}/feed.rss"),
          statuses: statuses
        )

      _ ->
        raise AbuubaWeb.NotFound, "no such account"
    end
  end

  @doc """
  Everything public on one hashtag.
  """
  def tag(conn, %{"tag" => tag}) do
    # The same question the page at /tags/:name asks, because this is that
    # timeline in another format. An admin who closed the timelines to
    # strangers closed this too, and a feed that answered anyway was a way to
    # read exactly what the page refused to show.
    statuses =
      if Settings.public_timelines_readable?(nil),
        do: Timelines.tag(tag, nil, feed_params()),
        else: []

    render_feed(conn,
      title: "#" <> tag,
      description: gettext("Public posts tagged #%{tag}", tag: tag),
      link: url(~p"/tags/#{tag}"),
      self: url(~p"/tags/#{tag}/feed.rss"),
      statuses: statuses
    )
  end

  # Never a boost, and never an unlisted post. See the module note.
  defp feed_params, do: %{limit: @limit, exclude_replies: true, exclude_reblogs: true}

  defp render_feed(conn, opts) do
    conn
    |> put_resp_content_type("application/rss+xml")
    |> send_resp(200, xml(opts))
  end

  defp xml(opts) do
    items = opts |> Keyword.fetch!(:statuses) |> Enum.filter(&public?/1) |> Enum.map(&item/1)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" \
    xmlns:atom="http://www.w3.org/2005/Atom">
    <channel>
    <title>#{escape(Keyword.fetch!(opts, :title))}</title>
    <description>#{escape(Keyword.fetch!(opts, :description))}</description>
    <link>#{escape(Keyword.fetch!(opts, :link))}</link>
    <atom:link rel="self" type="application/rss+xml" href="#{escape(Keyword.fetch!(opts, :self))}"/>
    #{Enum.join(items, "\n")}
    </channel>
    </rss>
    """
  end

  defp item(status) do
    uri = Serializer.status_uri(status)

    """
    <item>
    <guid isPermaLink="true">#{escape(uri)}</guid>
    <link>#{escape(uri)}</link>
    <title>#{escape(title(status))}</title>
    <pubDate>#{rfc_2822(status.inserted_at)}</pubDate>
    <description>#{escape(summary(status.text))}</description>
    <content:encoded><![CDATA[#{cdata_safe(status.text)}]]></content:encoded>
    </item>
    """
  end

  # The warning where there is one, so that a reader's list view carries the
  # warning rather than the thing it was warning about.
  defp title(%{spoiler_text: warning}) when is_binary(warning) and warning != "", do: warning

  defp title(status) do
    case summary(status.text) do
      "" -> gettext("A post")
      text -> String.slice(text, 0, 80)
    end
  end

  # `:public` and not `"public"`: the column is an enum, and a string here
  # would quietly filter out every post rather than only the unlisted ones.
  defp public?(%{visibility: :public}), do: true
  defp public?(_status), do: false

  defp display_name(%Account{display_name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%Account{username: username}), do: username

  defp summary(html) do
    html
    |> to_string()
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # `]]>` inside a CDATA section closes it early, and what follows is then read
  # as markup. Nothing in a post may end this block.
  defp cdata_safe(html), do: html |> to_string() |> String.replace("]]>", "]]&gt;")

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # RFC 2822, which is what RSS dates are, and deliberately not localised: a
  # date a reader has to parse is not a date anybody reads.
  defp rfc_2822(%DateTime{} = at) do
    day = Enum.at(@days, Date.day_of_week(at) - 1)
    month = Enum.at(@months, at.month - 1)

    "#{day}, #{pad(at.day)} #{month} #{at.year} " <>
      "#{pad(at.hour)}:#{pad(at.minute)}:#{pad(at.second)} +0000"
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end

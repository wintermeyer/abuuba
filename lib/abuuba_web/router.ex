defmodule AbuubaWeb.Router do
  use AbuubaWeb, :router

  import AbuubaWeb.UserAuth

  pipeline :browser do
    # Before `:accepts`: a machine asking a person's page for ActivityPub is
    # sent to the object the page is about, which is how a pasted abuuba address
    # comes to mean something on another server.
    plug AbuubaWeb.Plugs.MachineRedirect
    plug :accepts, ["html"]
    plug AbuubaWeb.Plugs.BlockedAddress
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AbuubaWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      # Phoenix stopped sending these for us, and nothing else was. Without
      # them any page here can be wrapped in somebody else's chrome and a click
      # aimed at their page lands on ours. `frame-ancestors` is the modern
      # spelling and `x-frame-options` is what older browsers read; both, since
      # the cost is two headers.
      "x-frame-options" => "DENY",
      "content-security-policy" => "frame-ancestors 'none'"
    }

    plug :fetch_current_scope
    plug AbuubaWeb.Plugs.Locale
    plug AbuubaWeb.Plugs.Accessibility
  end

  # The token has to be read before the rate limiter can tell whose budget a
  # request counts against. Cross-origin headers are not here: they are in the
  # endpoint, because a pipeline only runs once a route has matched and a
  # browser has to be able to read a 404 too.
  pipeline :api do
    # Before `:accepts`, which refuses a browser outright. The addresses abuuba
    # publishes to other servers are the ones people paste into a browser, and
    # a 406 there reads as the server being broken.
    plug AbuubaWeb.Plugs.HumanRedirect
    plug :accepts, ["json"]
    plug AbuubaWeb.Plugs.BlockedAddress
    plug AbuubaWeb.Plugs.OAuthToken
    # After the token, so a signed-in reader's own language setting wins over
    # the header their client happened to send.
    plug AbuubaWeb.Plugs.Locale
    plug AbuubaWeb.Plugs.APIRateLimit
  end

  # One pipeline per admin permission, so a route says what it needs where it
  # is declared. A check written into the controller is a check somebody has to
  # remember to write into the next one.
  # `RequireUser` first, so a request with no token is told it is not signed in
  # rather than that it is not allowed. "Not allowed" sends somebody hunting
  # for a missing permission when what they are missing is the token.
  pipeline :require_manage_users do
    plug AbuubaWeb.Plugs.RequireUser
    plug AbuubaWeb.Plugs.RequirePermission, "manage_users"
  end

  pipeline :require_manage_reports do
    plug AbuubaWeb.Plugs.RequireUser
    plug AbuubaWeb.Plugs.RequirePermission, "manage_reports"
  end

  pipeline :require_manage_taxonomies do
    plug AbuubaWeb.Plugs.RequireUser
    plug AbuubaWeb.Plugs.RequirePermission, "manage_taxonomies"
  end

  pipeline :require_manage_federation do
    plug AbuubaWeb.Plugs.RequireUser
    plug AbuubaWeb.Plugs.RequirePermission, "manage_federation"
  end

  pipeline :require_manage_blocks do
    plug AbuubaWeb.Plugs.RequireUser
    plug AbuubaWeb.Plugs.RequirePermission, "manage_blocks"
  end

  # Making accounts is the one thing an unattended client can do that costs
  # this server rows nobody asked for, so it gets a budget of its own rather
  # than the general API one. Without it a single token buys three hundred
  # accounts every five minutes, and tokens are free to mint.
  pipeline :sign_up do
    plug AbuubaWeb.Plugs.APIRateLimit, bucket: :sign_up
  end

  # Registration is unauthenticated by necessity, so it is the one API endpoint
  # a stranger can fill a table through. The API limiter rather than the HTML
  # one: this route has no session, so a refusal that set a flash and
  # redirected would raise instead of answering.
  pipeline :app_registration do
    plug AbuubaWeb.Plugs.APIRateLimit, bucket: :app_registration
  end

  # Enough headroom that a person retyping a password never notices, and low
  # enough that guessing at one is not worth starting.
  # What other servers fetch: webfinger, actors, posts, collections, and the
  # inboxes they deliver to. Everything the :api pipeline runs except the rate
  # limiter and the token plug -- deliberately. A peer server dereferencing a
  # busy thread makes hundreds of requests from a handful of addresses, and
  # counting those against the per-address API budget meant one lively peer
  # starved itself: abuuba answered 429 to its webfinger, which reads as this
  # whole server being down. The reference implementation throttles only its
  # /api paths and never the federation surface, for exactly this reason. The
  # interop suite found it -- half a peer's scenarios collapsed mid-run and
  # recovered when the window rolled.
  pipeline :federation do
    plug AbuubaWeb.Plugs.HumanRedirect
    plug :accepts, ["json"]
    plug AbuubaWeb.Plugs.BlockedAddress
    plug AbuubaWeb.Plugs.Locale
  end

  pipeline :auth_attempts do
    plug AbuubaWeb.Plugs.RateLimit, bucket: "auth", limit: 20, window_ms: 60_000
  end

  # One address, two answers. The invite link is followed by people in a browser
  # and read by clients that want to know who is inviting before they render a
  # sign-up screen, and the reference implementation answers both on the same
  # path. Session and flash because the browser half redirects with a message.
  pipeline :invite do
    plug :accepts, ["html", "json"]
    plug AbuubaWeb.Plugs.BlockedAddress
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_secure_browser_headers
    plug AbuubaWeb.Plugs.Locale
  end

  # Everything else refuses framing. An embed exists to be framed, so it gets a
  # pipeline that leaves that decision to the controller and nothing else does.
  pipeline :embed do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {AbuubaWeb.Layouts, :root}
    plug :put_secure_browser_headers
    plug AbuubaWeb.Plugs.Locale
  end

  # No pipeline at all. A load balancer's check should not depend on session
  # decoding, on a locale, on a rate limiter, or on anything else that could
  # take the instance out of rotation for a reason that has nothing to do with
  # whether it can serve.
  scope "/", AbuubaWeb do
    get "/health", HealthController, :alive
    get "/health/ready", HealthController, :ready
  end

  # Another server's file, served from this one so that a reader's address is
  # not twelve other servers' business. No session and no locale: it answers
  # with bytes, and everything it needs is in the path.
  pipeline :media_proxy do
    plug AbuubaWeb.Plugs.BlockedAddress
  end

  scope "/", AbuubaWeb do
    pipe_through :media_proxy

    get "/media_proxy/:id/:style", MediaProxyController, :show
  end

  scope "/", AbuubaWeb do
    pipe_through :invite

    # The short address that goes in the message somebody sends a friend. HTML
    # lands on the sign-up form with the code applied; a client asking for JSON
    # gets the invite itself.
    get "/invite/:invite_code", InviteController, :show
  end

  scope "/", AbuubaWeb do
    pipe_through :embed

    get "/embed/:id", EmbedController, :show

    # The bare file, for somebody else's page to frame. Same pipeline as an
    # embed and for the same reason: everything else here refuses framing.
    get "/media/:id/player", MediaController, :player
  end

  scope "/", AbuubaWeb do
    pipe_through :browser

    get "/shortcuts", ShortcutsController, :show

    # What lets somebody add this server to a home screen, and the admin's own
    # stylesheet.
    get "/manifest", WebAppController, :manifest
    get "/manifest.json", WebAppController, :manifest
    get "/custom.css", WebAppController, :custom_css

    # One click from inside a message. A GET shows the page and a POST acts,
    # because mail clients fetch every link before anybody reads it.
    get "/unsubscribe/:token", UnsubscribeController, :show
    post "/unsubscribe/:token", UnsubscribeController, :update

    # A media link, sent to the post the file belongs to: that is where it has
    # its caption, its author and its thread.
    get "/media/:id", MediaController, :show

    # Feeds, for somebody who wants to read one person or one subject without
    # an account anywhere. Outside the live session because a feed is a file.
    get "/@:username/feed.rss", FeedController, :account
    get "/tags/:tag/feed.rss", FeedController, :tag

    live_session :shell,
      on_mount: [{AbuubaWeb.UserAuth, :mount_current_scope}, AbuubaWeb.LocaleHook] do
      live "/", LandingLive
      live "/about", AboutLive
      live "/terms", DocumentLive, :terms
      live "/terms/:date", DocumentLive, :terms
      live "/privacy", DocumentLive, :privacy
      live "/authorize_interaction", InteractionLive
      live "/explore", ExploreLive, :posts
      live "/explore/tags", ExploreLive, :tags
      live "/explore/people", ExploreLive, :people
      live "/search", SearchLive
      live "/tags/:name", TagLive
      live "/collections/:id", CollectionLive
      live "/@:username/year/:year", AnnualReportLive

      # Public pages, and the addresses this server hands out for a person and
      # a post. Signed in or not, these render on the server: somebody
      # following a link and every link preview reads real HTML.
      live "/@:username", ProfileLive, :posts
      live "/@:username/with_replies", ProfileLive, :with_replies
      live "/@:username/media", ProfileLive, :media
      # Public, and honouring `hide_collections`. Above `/@:username/:id`, or
      # "followers" is read as a post id.
      live "/@:username/followers", ProfileLive, :followers
      live "/@:username/following", ProfileLive, :following
      # The address a featured hashtag points at, here and in the actor
      # document every peer reads. Above `/@:username/:id`, or a tag name is
      # taken for a post id.
      live "/@:username/tagged/:tag", ProfileLive, :tagged
      live "/@:username/:id", StatusLive, :show
    end

    post "/locale", LocaleController, :update
    get "/api/oembed", OEmbedController, :show
    get "/confirm/:token", ConfirmationController, :confirm

    # Both acts are POSTs from the page rather than the link itself, so that a
    # mail client fetching every link in a message does not confirm or
    # unsubscribe on somebody's behalf.
    get "/email_subscriptions/:token", EmailSubscriptionController, :show
    post "/email_subscriptions/:token/confirm", EmailSubscriptionController, :confirm
    post "/email_subscriptions/:token/unsubscribe", EmailSubscriptionController, :unsubscribe
    delete "/logout", SessionController, :delete
  end

  scope "/", AbuubaWeb do
    pipe_through [:browser, :auth_attempts, :redirect_if_user_is_authenticated]

    post "/login", SessionController, :create
    post "/login/two-factor", SessionController, :two_factor

    # Behind the same limiter as signing in, and for the same reason: it is a
    # form a stranger can post to as often as they like, and each post either
    # sends mail or tells them something about an address.
    post "/reset-password", PasswordResetController, :create
    post "/reset-password/:token", PasswordResetController, :update
  end

  # The pages themselves, outside the attempt limiter. A limiter that counts
  # attempts should count attempts: loading the sign-in form twenty times is
  # not twenty tries at a password, and spending the budget on page loads means
  # somebody who reads the forgotten-password page a few times cannot then sign
  # in. The posts above are where the guessing happens and they are still
  # counted.
  scope "/", AbuubaWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :signed_out,
      on_mount: [{AbuubaWeb.UserAuth, :mount_current_scope}, AbuubaWeb.LocaleHook] do
      live "/register", RegistrationLive
      live "/login", LoginLive
      live "/login/two-factor", TwoFactorLive
      live "/reset-password", PasswordResetLive
      live "/reset-password/:token", PasswordResetLive
    end
  end

  scope "/", AbuubaWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Files rather than pages, so a controller rather than a LiveView: a socket
    # has no response to hang `content-disposition` on.
    get "/settings/export/lists/:kind", ExportController, :csv

    # The domain lists as files, for the same reason: a socket has no response
    # to hang `content-disposition` on.
    get "/admin/domain-lists/:kind/download", DomainListController, :export
    get "/settings/export/archives/:id/download", ExportController, :archive

    live_session :signed_in,
      on_mount: [{AbuubaWeb.UserAuth, :ensure_authenticated}, AbuubaWeb.LocaleHook] do
      live "/follow-requests", FollowRequestsLive
      live "/report/@:username", ReportLive
      live "/bookmarks", SavedLive, :bookmarks
      live "/favourites", SavedLive, :favourites
      live "/settings/two-factor", TwoFactorSettingsLive
      live "/settings", SettingsLive, :index
      live "/settings/profile", SettingsLive, :profile
      live "/settings/appearance", SettingsLive, :appearance
      live "/settings/posting", SettingsLive, :posting
      live "/settings/privacy", SettingsLive, :privacy
      live "/settings/filters", SettingsLive, :filters
      live "/settings/follows", SettingsLive, :follows
      live "/settings/security", SettingsLive, :security
      live "/settings/applications", SettingsLive, :applications
      live "/settings/account", SettingsLive, :account
      live "/settings/moderation", SettingsLive, :strikes
      live "/settings/import", SettingsLive, :import
      live "/settings/export", SettingsLive, :export
      live "/settings/invites", SettingsLive, :invites
      live "/home", HomeLive
      live "/conversations", ConversationsLive
      live "/share", ShareLive
      live "/settings/notifications", NotificationSettingsLive
      live "/notifications", NotificationsLive, :all
      live "/notifications/mentions", NotificationsLive, :mentions
    end

    live_session :admin,
      on_mount: [
        {AbuubaWeb.UserAuth, :ensure_authenticated},
        {AbuubaWeb.AdminAuth,
         {:require_any, ~w(view_dashboard manage_users manage_settings view_audit_log
             manage_taxonomies manage_announcements manage_blocks manage_federation
             manage_webhooks manage_roles manage_reports manage_custom_emojis)}},
        AbuubaWeb.LocaleHook
      ] do
      live "/admin", AdminLive, :dashboard
      live "/admin/accounts", AdminLive, :accounts
      live "/admin/accounts/:id", AdminLive, :account
      live "/admin/emoji", AdminLive, :emoji
      live "/admin/reports", AdminLive, :reports
      live "/admin/reports/:id", AdminLive, :report
      live "/admin/appeals", AdminLive, :appeals
      live "/admin/trends", AdminLive, :trends
      live "/admin/announcements", AdminLive, :announcements
      live "/admin/signups", AdminLive, :signups
      live "/admin/relays", AdminLive, :relays
      live "/admin/instances", AdminLive, :instances
      live "/admin/domain-lists", AdminLive, :domain_lists
      live "/admin/suggestions", AdminLive, :suggestions
      live "/admin/subscriptions", AdminLive, :subscriptions
      live "/admin/webhooks", AdminLive, :webhooks
      live "/admin/roles", AdminLive, :roles
      live "/admin/settings", AdminLive, :settings
      live "/admin/audit-log", AdminLive, :audit
    end
  end

  scope "/", AbuubaWeb do
    pipe_through :api

    post "/oauth/token", OAuthController, :token
    post "/oauth/revoke", OAuthController, :revoke
    get "/.well-known/oauth-authorization-server", OAuthController, :metadata

    # The same document under the name a single-sign-on client looks for, plus
    # the endpoint it reads an identity from. Some clients will not talk to a
    # server that does not answer both.
    get "/.well-known/openid-configuration", OAuthController, :metadata
    get "/oauth/userinfo", OAuthController, :userinfo
    post "/oauth/userinfo", OAuthController, :userinfo
    # Where a password manager looks to offer "change your password here".
    # A redirect rather than a page, which is what the convention specifies,
    # and it lands on the settings section that already does the job.
    get "/.well-known/change-password", WellKnownController, :change_password
  end

  scope "/", AbuubaWeb do
    pipe_through :federation

    get "/.well-known/webfinger", WellKnownController, :webfinger
    get "/.well-known/host-meta", WellKnownController, :host_meta

    # Actors, in both URI schemes. See the migration that added `id_scheme`
    # for why both have to keep working.
    get "/actor", ActivityPubController, :instance_actor
    get "/users/:username", ActivityPubController, :show
    get "/users/:username/followers", ActivityPubController, :followers
    get "/users/:username/following", ActivityPubController, :following
    get "/users/:username/outbox", ActivityPubController, :outbox
    get "/ap/users/:id", ActivityPubController, :show_by_id

    # The same three collections under the numeric id shape. The actor
    # document builds these by appending to its own id, so an account imported
    # from Mastodon advertised them here -- and until these routes existed,
    # every one of those URLs answered 404. The inbox below is the one that
    # bit: a peer that cannot POST to somebody's inbox cannot deliver to them,
    # so a follow of an imported account was accepted and nothing ever arrived.
    get "/ap/users/:account_id/followers", ActivityPubController, :followers
    get "/ap/users/:account_id/following", ActivityPubController, :following
    get "/ap/users/:account_id/outbox", ActivityPubController, :outbox

    # A curated list, as a peer reads it. A separate address from the page,
    # the same way a post has one: `uri` is what other servers point at and
    # `url` is what a person opens.
    get "/ap/collections/:id", ActivityPubController, :collection

    # A post, at the address every activity about it points at. Without these
    # the ids abuuba puts in every Create, Announce, Like and Delete resolve to
    # nothing, and a peer cannot thread a reply or act on a bare URI.
    get "/users/:username/statuses/:id", ActivityPubController, :status
    get "/users/:username/statuses/:id/activity", ActivityPubController, :status_activity
    get "/ap/users/:account_id/statuses/:id", ActivityPubController, :status
    get "/ap/users/:account_id/statuses/:id/activity", ActivityPubController, :status_activity

    # What hangs off a post. `replies` is the one that does work: a peer walks
    # it to fill in a thread it received out of order.
    get "/users/:username/statuses/:id/quote_authorizations/:quote_id",
        ActivityPubController,
        :quote_authorization

    get "/ap/users/:account_id/statuses/:id/quote_authorizations/:quote_id",
        ActivityPubController,
        :quote_authorization

    get "/users/:username/statuses/:id/replies", ActivityPubController, :status_replies
    get "/users/:username/statuses/:id/likes", ActivityPubController, :status_likes
    get "/users/:username/statuses/:id/shares", ActivityPubController, :status_shares
    # What an account has put on its own profile, which the actor document
    # points at: pinned posts and featured hashtags.
    get "/users/:username/collections/:id", ActivityPubController, :actor_collection
    get "/ap/users/:account_id/collections/:id", ActivityPubController, :actor_collection

    get "/ap/users/:account_id/statuses/:id/replies", ActivityPubController, :status_replies
    get "/ap/users/:account_id/statuses/:id/likes", ActivityPubController, :status_likes
    get "/ap/users/:account_id/statuses/:id/shares", ActivityPubController, :status_shares

    # Both inboxes do the same thing. Which one a peer used says something
    # about how they batched delivery and nothing about what the activity
    # means; the audience inside it decides who it reaches.
    post "/inbox", InboxController, :create
    post "/users/:username/inbox", InboxController, :create
    post "/ap/users/:account_id/inbox", InboxController, :create
    post "/actor/inbox", InboxController, :create
  end

  scope "/", AbuubaWeb do
    pipe_through :api

    get "/api/v1/apps/verify_credentials", AppController, :verify_credentials

    # The statuses family. Every un-action is a POST rather than a DELETE: it
    # reads as a mistake and it is what every client sends, so an endpoint that
    # only answered DELETE would leave the button in an app doing nothing.
    # The path apps were written against before collections settled on v1.
    # Answered rather than redirected: a client that gets a 404 shows an error
    # where it meant to show a list.
    scope "/api/v1_alpha" do
      get "/async_refreshes/:id", API.AsyncRefreshController, :show
      get "/collections/:id", API.CuratedListController, :show
      post "/collections", API.CuratedListController, :create
      put "/collections/:id", API.CuratedListController, :update
      patch "/collections/:id", API.CuratedListController, :update
      delete "/collections/:id", API.CuratedListController, :delete
      post "/collections/:collection_id/items", API.CuratedListController, :add_item
      delete "/collections/:collection_id/items/:id", API.CuratedListController, :delete_item
      post "/collections/:collection_id/items/:id/revoke", API.CuratedListController, :revoke_item
      get "/accounts/:account_id/collections", API.CuratedListController, :by_account
      get "/accounts/:account_id/in_collections", API.CuratedListController, :containing_account
    end

    scope "/api/v1" do
      get "/statuses", API.StatusController, :index
      post "/reports", API.ReportController, :create
      post "/statuses", API.StatusController, :create
      get "/statuses/:id", API.StatusController, :show
      put "/statuses/:id", API.StatusController, :update
      delete "/statuses/:id", API.StatusController, :delete

      get "/statuses/:id/context", API.StatusController, :context
      get "/statuses/:id/source", API.StatusController, :source
      get "/statuses/:id/history", API.StatusController, :history
      get "/statuses/:id/reblogged_by", API.StatusController, :reblogged_by
      get "/statuses/:id/favourited_by", API.StatusController, :favourited_by

      post "/statuses/:id/reblog", API.StatusController, :reblog
      post "/statuses/:id/unreblog", API.StatusController, :unreblog
      post "/statuses/:id/favourite", API.StatusController, :favourite
      post "/statuses/:id/unfavourite", API.StatusController, :unfavourite
      post "/statuses/:id/bookmark", API.StatusController, :bookmark
      post "/statuses/:id/unbookmark", API.StatusController, :unbookmark
      post "/statuses/:id/mute", API.StatusController, :mute
      post "/statuses/:id/unmute", API.StatusController, :unmute
      post "/statuses/:id/pin", API.StatusController, :pin
      post "/statuses/:id/unpin", API.StatusController, :unpin
      post "/statuses/:id/translate", API.StatusController, :translate

      # Quotes. The list is the quoted author's own post's; revoking is theirs
      # too, which is why both hang off the quoted status rather than the
      # quoting one.
      get "/statuses/:id/quotes", API.StatusController, :quotes
      post "/statuses/:status_id/quotes/:id/revoke", API.StatusController, :revoke_quote
      put "/statuses/:id/interaction_policy", API.StatusController, :interaction_policy

      # The accounts family. Order matters: the fixed paths have to be declared
      # before `/accounts/:id`, or "verify_credentials" is read as an id.
      # The profile family. `/profile` is what somebody edits; `/accounts/:id`
      # is what everybody else reads, and the two answer different questions.
      get "/profile", API.AccountController, :profile
      put "/profile", API.AccountController, :update_profile
      patch "/profile", API.AccountController, :update_profile
      delete "/profile/:kind", API.AccountController, :remove_picture

      # A batch fetch by id, above `/accounts/:id` for the same reason as the
      # rest of this block. Signing up is a route of its own, further down: it
      # needs a throttle the ordinary API budget does not give it.
      get "/accounts", API.AccountController, :index

      get "/accounts/verify_credentials", API.AccountController, :verify_credentials
      patch "/accounts/update_credentials", API.AccountController, :update_credentials
      get "/accounts/relationships", API.AccountController, :relationships
      get "/accounts/familiar_followers", API.AccountController, :familiar_followers
      get "/accounts/lookup", API.AccountController, :lookup
      get "/accounts/search", API.AccountController, :search
      get "/accounts/:id", API.AccountController, :show
      # Curated lists of accounts. Reading one needs no token: the point of a
      # collection is to be handed to somebody who has not signed up yet.
      get "/collections/:id", API.CuratedListController, :show
      post "/collections", API.CuratedListController, :create
      put "/collections/:id", API.CuratedListController, :update
      patch "/collections/:id", API.CuratedListController, :update
      delete "/collections/:id", API.CuratedListController, :delete
      post "/collections/:collection_id/items", API.CuratedListController, :add_item
      delete "/collections/:collection_id/items/:id", API.CuratedListController, :delete_item
      post "/collections/:collection_id/items/:id/revoke", API.CuratedListController, :revoke_item
      get "/accounts/:account_id/collections", API.CuratedListController, :by_account
      get "/accounts/:account_id/in_collections", API.CuratedListController, :containing_account

      get "/accounts/:id/statuses", API.AccountController, :statuses
      get "/accounts/:id/featured_tags", API.AccountController, :featured_tags
      get "/accounts/:id/endorsements", API.AccountController, :endorsements
      get "/accounts/:id/lists", API.AccountController, :lists
      get "/accounts/:id/identity_proofs", API.AccountController, :identity_proofs
      get "/accounts/:id/followers", API.AccountController, :followers
      get "/accounts/:id/following", API.AccountController, :following

      post "/accounts/:id/follow", API.AccountController, :follow
      post "/accounts/:id/unfollow", API.AccountController, :unfollow
      post "/accounts/:id/block", API.AccountController, :block
      post "/accounts/:id/unblock", API.AccountController, :unblock
      post "/accounts/:id/mute", API.AccountController, :mute
      post "/accounts/:id/unmute", API.AccountController, :unmute
      post "/accounts/:id/note", API.AccountController, :note

      # Four spellings of two acts. `pin`/`unpin` came first and `endorse`/
      # `unendorse` replaced them; both are still sent by clients in the wild.
      post "/accounts/:id/pin", API.AccountController, :endorse
      post "/accounts/:id/endorse", API.AccountController, :endorse
      post "/accounts/:id/unpin", API.AccountController, :unendorse
      post "/accounts/:id/unendorse", API.AccountController, :unendorse
      post "/accounts/:id/remove_from_followers", API.AccountController, :remove_from_followers

      get "/push/subscription", API.PushSubscriptionController, :show
      post "/push/subscription", API.PushSubscriptionController, :create
      put "/push/subscription", API.PushSubscriptionController, :update
      delete "/push/subscription", API.PushSubscriptionController, :delete

      get "/streaming", API.StreamingController, :socket
      get "/streaming/health", API.StreamingController, :health
      get "/streaming/:stream", API.StreamingController, :stream

      get "/custom_emojis", API.InstanceInfoController, :custom_emojis
      get "/preferences", API.InstanceInfoController, :preferences
      get "/announcements", API.InstanceInfoController, :announcements
      post "/announcements/:id/dismiss", API.InstanceInfoController, :dismiss_announcement
      put "/announcements/:id/reactions/:name", API.InstanceInfoController, :react
      delete "/announcements/:id/reactions/:name", API.InstanceInfoController, :unreact

      get "/emails/check_confirmation", API.EmailController, :check

      # The year in review. `state` and `generate` take a year rather than a
      # report id: a client asks about a year it has no report for.
      get "/annual_reports", API.AnnualReportController, :index
      get "/annual_reports/:id/state", API.AnnualReportController, :state
      post "/annual_reports/:id/generate", API.AnnualReportController, :generate
      post "/annual_reports/:id/read", API.AnnualReportController, :read
      get "/annual_reports/:id", API.AnnualReportController, :show

      # The appeal this server's admin wrote, if there is one. 204 rather
      # than 404 where there is not: having no campaign is the ordinary
      # case, and a client should not be logging it as a failure.
      get "/donation_campaigns", API.DonationCampaignController, :index

      # Open on purpose: the person subscribing is usually not a member here,
      # which is the point. The controller explains what stops it being a way
      # to mail strangers.
      post "/accounts/:account_id/email_subscriptions",
           API.EmailSubscriptionController,
           :create

      get "/instance/peers", API.InstanceInfoController, :peers
      get "/instance/privacy_policy", API.InstanceInfoController, :privacy_policy
      get "/instance/languages", API.InstanceInfoController, :languages
      get "/peers/search", API.InstanceInfoController, :peers_search
      get "/domain_blocks/preview", API.InstanceInfoController, :domain_block_preview
      get "/instance/rules", API.InstanceInfoController, :rules
      get "/instance/activity", API.InstanceInfoController, :activity
      get "/instance/domain_blocks", API.InstanceInfoController, :domain_blocks
      get "/instance/extended_description", API.InstanceInfoController, :extended_description
      get "/instance/translation_languages", API.InstanceInfoController, :translation_languages
      get "/instance/terms_of_service", API.InstanceInfoController, :terms_of_service
      get "/instance/terms_of_service/:date", API.InstanceInfoController, :terms_of_service

      # `/trends` without a kind is what clients written before the namespace
      # existed still call, and it means tags.
      get "/trends", API.InstanceInfoController, :trending_tags
      get "/trends/tags", API.InstanceInfoController, :trending_tags
      get "/trends/statuses", API.InstanceInfoController, :trending_statuses
      get "/trends/links", API.InstanceInfoController, :trending_links

      get "/followed_tags", API.InstanceInfoController, :followed_tags

      # Above `/tags/:id`, so that "suggestions" is not read as a tag name.
      get "/featured_tags/suggestions", API.FeaturedTagController, :suggestions
      get "/featured_tags", API.FeaturedTagController, :index
      post "/featured_tags", API.FeaturedTagController, :create
      delete "/featured_tags/:id", API.FeaturedTagController, :delete

      get "/tags/:id", API.InstanceInfoController, :show_tag
      post "/tags/:id/follow", API.InstanceInfoController, :follow_tag
      post "/tags/:id/unfollow", API.InstanceInfoController, :unfollow_tag
      post "/tags/:id/feature", API.InstanceInfoController, :feature_tag
      post "/tags/:id/unfeature", API.InstanceInfoController, :unfeature_tag

      get "/lists", API.ListController, :index
      post "/lists", API.ListController, :create
      get "/lists/:id", API.ListController, :show
      put "/lists/:id", API.ListController, :update
      delete "/lists/:id", API.ListController, :delete
      get "/lists/:id/accounts", API.ListController, :accounts
      post "/lists/:id/accounts", API.ListController, :add_accounts
      delete "/lists/:id/accounts", API.ListController, :remove_accounts

      get "/filters/keywords/:id", API.FilterController, :show_keyword
      put "/filters/keywords/:id", API.FilterController, :update_keyword
      delete "/filters/keywords/:id", API.FilterController, :delete_keyword
      get "/filters/statuses/:id", API.FilterController, :show_status
      delete "/filters/statuses/:id", API.FilterController, :delete_status

      # The older shape of the same rows, where an id names a keyword rather
      # than the rule it belongs to. Below the keyword routes above, because
      # `/filters/keywords/:id` has to keep meaning what it says.
      get "/filters", API.FilterV1Controller, :index
      post "/filters", API.FilterV1Controller, :create
      get "/filters/:id", API.FilterV1Controller, :show
      put "/filters/:id", API.FilterV1Controller, :update
      patch "/filters/:id", API.FilterV1Controller, :update
      delete "/filters/:id", API.FilterV1Controller, :delete

      get "/favourites", API.CollectionController, :favourites
      get "/bookmarks", API.CollectionController, :bookmarks
      get "/conversations", API.CollectionController, :conversations
      post "/conversations/:id/read", API.CollectionController, :read_conversation
      post "/conversations/:id/unread", API.CollectionController, :unread_conversation
      delete "/conversations/:id", API.CollectionController, :delete_conversation

      post "/media", API.MediaController, :create
      get "/media/:id", API.MediaController, :show
      put "/media/:id", API.MediaController, :update
      delete "/media/:id", API.MediaController, :delete

      get "/notifications", API.NotificationController, :index
      get "/notifications/unread_count", API.NotificationController, :unread_count
      get "/severed_relationships", API.SeveranceController, :index

      get "/invites", API.InviteController, :index
      post "/invites", API.InviteController, :create
      delete "/invites/:id", API.InviteController, :delete

      # The moderation client's half of the admin area. Each route names the
      # permission it needs rather than trusting the one before it.
      scope "/admin" do
        pipe_through [:require_manage_users]

        get "/accounts", API.AdminController, :accounts
        get "/accounts/:id", API.AdminController, :account
        post "/accounts/:id/action", API.AdminController, :account_action
        post "/accounts/:id/approve", API.AdminController, :approve
        post "/accounts/:id/reject", API.AdminController, :reject
        post "/accounts/:id/enable", API.AdminController, :enable
        post "/accounts/:id/unsilence", API.AdminController, :unsilence
        post "/accounts/:id/unsuspend", API.AdminController, :unsuspend
        post "/accounts/:id/remove_avatar", API.AdminController, :remove_avatar
        post "/accounts/:id/remove_header", API.AdminController, :remove_header
        post "/accounts/:id/unsensitive", API.AdminController, :unsensitive
        delete "/accounts/:id", API.AdminController, :delete_account
      end

      # The dashboard's numbers. `manage_users` rather than a permission of
      # their own: they are counts of what the people here are doing, and the
      # screen that draws them is the one a moderator already has.
      scope "/admin" do
        pipe_through [:require_manage_users]

        post "/measures", API.AdminController, :measures
        post "/dimensions", API.AdminController, :dimensions
        get "/retention", API.AdminController, :retention
        post "/retention", API.AdminController, :retention
      end

      scope "/admin" do
        pipe_through [:require_manage_reports]

        get "/reports", API.AdminController, :reports
        get "/reports/:id", API.AdminController, :report
        post "/reports/:id/resolve", API.AdminController, :resolve_report
        post "/reports/:id/reopen", API.AdminController, :reopen_report
        post "/reports/:id/assign_to_self", API.AdminController, :assign_report
        post "/reports/:id/unassign", API.AdminController, :unassign_report
        put "/reports/:id", API.AdminController, :update_report
      end

      scope "/admin" do
        pipe_through [:require_manage_taxonomies]

        # Above `/trends/:kind`, or "links" is read as a kind and "publishers"
        # as a subject.
        get "/trends/links/publishers", API.AdminController, :link_publishers

        post "/trends/links/publishers/:provider/:decision",
             API.AdminController,
             :review_publisher

        get "/trends/:kind", API.AdminController, :trends
        post "/trends/:kind/:subject/:decision", API.AdminController, :review_trend

        get "/tags", API.AdminController, :tags
        get "/tags/:id", API.AdminController, :tag
        put "/tags/:id", API.AdminController, :update_tag
      end

      scope "/admin" do
        pipe_through [:require_manage_federation]

        get "/domain_blocks", API.AdminController, :domain_blocks
        post "/domain_blocks", API.AdminController, :create_domain_block
        get "/domain_blocks/:id", API.AdminController, :domain_block
        put "/domain_blocks/:id", API.AdminController, :update_domain_block
        delete "/domain_blocks/:id", API.AdminController, :delete_domain_block

        # Who this server talks to at all, which is the same decision as a
        # domain block seen from the other side.
        get "/domain_allows", API.AdminController, :domain_allows
        post "/domain_allows", API.AdminController, :create_domain_allow
        get "/domain_allows/:id", API.AdminController, :domain_allow
        delete "/domain_allows/:id", API.AdminController, :delete_domain_allow
      end

      # Who may sign up, which is a different permission from who this server
      # federates with: the reference implementation splits them the same way.
      scope "/admin" do
        pipe_through [:require_manage_blocks]

        get "/email_domain_blocks", API.AdminController, :email_domain_blocks
        post "/email_domain_blocks", API.AdminController, :create_email_domain_block
        get "/email_domain_blocks/:id", API.AdminController, :email_domain_block
        delete "/email_domain_blocks/:id", API.AdminController, :delete_email_domain_block

        get "/ip_blocks", API.AdminController, :ip_blocks
        post "/ip_blocks", API.AdminController, :create_ip_block
        get "/ip_blocks/:id", API.AdminController, :ip_block
        put "/ip_blocks/:id", API.AdminController, :update_ip_block
        delete "/ip_blocks/:id", API.AdminController, :delete_ip_block

        # Above `/:id`, or "test" is read as one.
        post "/canonical_email_blocks/test", API.AdminController, :test_canonical_email_block
        get "/canonical_email_blocks", API.AdminController, :canonical_email_blocks
        post "/canonical_email_blocks", API.AdminController, :create_canonical_email_block
        get "/canonical_email_blocks/:id", API.AdminController, :canonical_email_block
        delete "/canonical_email_blocks/:id", API.AdminController, :delete_canonical_email_block
      end

      post "/notifications/clear", API.NotificationController, :clear
      get "/notifications/policy", API.NotificationController, :get_policy
      put "/notifications/policy", API.NotificationController, :put_policy
      get "/notifications/requests", API.NotificationController, :requests
      get "/notifications/requests/merged", API.NotificationController, :requests_merged
      post "/notifications/requests/accept", API.NotificationController, :accept_requests
      post "/notifications/requests/dismiss", API.NotificationController, :dismiss_requests
      post "/notifications/requests/:id/accept", API.NotificationController, :accept_request
      post "/notifications/requests/:id/dismiss", API.NotificationController, :dismiss_request
      get "/notifications/requests/:id", API.NotificationController, :show_request
      get "/notifications/:id", API.NotificationController, :show
      post "/notifications/:id/dismiss", API.NotificationController, :dismiss

      get "/timelines/home", API.TimelineController, :home
      get "/timelines/public", API.TimelineController, :public
      get "/timelines/tag/:hashtag", API.TimelineController, :tag
      get "/timelines/list/:id", API.TimelineController, :list
      get "/timelines/link", API.TimelineController, :link

      get "/markers", API.TimelineController, :get_markers
      post "/markers", API.TimelineController, :put_markers

      get "/blocks", API.RelationshipController, :blocks
      get "/mutes", API.RelationshipController, :mutes
      get "/follow_requests", API.RelationshipController, :follow_requests
      post "/follow_requests/:id/authorize", API.RelationshipController, :authorize
      post "/follow_requests/:id/reject", API.RelationshipController, :reject
      get "/domain_blocks", API.RelationshipController, :domain_blocks
      post "/domain_blocks", API.RelationshipController, :block_domain
      delete "/domain_blocks", API.RelationshipController, :unblock_domain

      get "/directory", API.DirectoryController, :index
      get "/suggestions", API.DirectoryController, :suggestions
      delete "/suggestions/:id", API.DirectoryController, :dismiss_suggestion
      get "/endorsements", API.DirectoryController, :endorsements

      get "/polls/:id", API.PollController, :show
      post "/polls/:id/votes", API.PollController, :vote

      get "/scheduled_statuses", API.ScheduledStatusController, :index
      get "/scheduled_statuses/:id", API.ScheduledStatusController, :show
      put "/scheduled_statuses/:id", API.ScheduledStatusController, :update
      delete "/scheduled_statuses/:id", API.ScheduledStatusController, :delete
    end

    get "/.well-known/nodeinfo", InstanceController, :well_known_nodeinfo
    get "/nodeinfo/2.0", InstanceController, :nodeinfo
    get "/api/v2/instance", InstanceController, :show_v2

    scope "/api/v2" do
      # The same list, under the version a newer moderation client asks on.
      scope "/admin" do
        pipe_through [:require_manage_users]

        get "/accounts", API.AdminController, :accounts
      end

      get "/push/subscription", API.PushSubscriptionController, :show
      post "/push/subscription", API.PushSubscriptionController, :create
      put "/push/subscription", API.PushSubscriptionController, :update
      delete "/push/subscription", API.PushSubscriptionController, :delete

      get "/streaming", API.StreamingController, :socket
      get "/streaming/health", API.StreamingController, :health
      get "/streaming/:stream", API.StreamingController, :stream

      get "/custom_emojis", API.InstanceInfoController, :custom_emojis
      get "/preferences", API.InstanceInfoController, :preferences
      get "/announcements", API.InstanceInfoController, :announcements
      post "/announcements/:id/dismiss", API.InstanceInfoController, :dismiss_announcement
      put "/announcements/:id/reactions/:name", API.InstanceInfoController, :react
      delete "/announcements/:id/reactions/:name", API.InstanceInfoController, :unreact

      get "/emails/check_confirmation", API.EmailController, :check

      # The year in review. `state` and `generate` take a year rather than a
      # report id: a client asks about a year it has no report for.
      get "/annual_reports", API.AnnualReportController, :index
      get "/annual_reports/:id/state", API.AnnualReportController, :state
      post "/annual_reports/:id/generate", API.AnnualReportController, :generate
      post "/annual_reports/:id/read", API.AnnualReportController, :read
      get "/annual_reports/:id", API.AnnualReportController, :show

      get "/instance/peers", API.InstanceInfoController, :peers
      get "/instance/privacy_policy", API.InstanceInfoController, :privacy_policy
      get "/instance/languages", API.InstanceInfoController, :languages
      get "/peers/search", API.InstanceInfoController, :peers_search
      get "/domain_blocks/preview", API.InstanceInfoController, :domain_block_preview
      get "/instance/rules", API.InstanceInfoController, :rules
      get "/instance/activity", API.InstanceInfoController, :activity
      get "/instance/domain_blocks", API.InstanceInfoController, :domain_blocks
      get "/instance/extended_description", API.InstanceInfoController, :extended_description
      get "/instance/translation_languages", API.InstanceInfoController, :translation_languages
      get "/instance/terms_of_service", API.InstanceInfoController, :terms_of_service
      get "/instance/terms_of_service/:date", API.InstanceInfoController, :terms_of_service

      # `/trends` without a kind is what clients written before the namespace
      # existed still call, and it means tags.
      get "/trends", API.InstanceInfoController, :trending_tags
      get "/trends/tags", API.InstanceInfoController, :trending_tags
      get "/trends/statuses", API.InstanceInfoController, :trending_statuses
      get "/trends/links", API.InstanceInfoController, :trending_links

      get "/followed_tags", API.InstanceInfoController, :followed_tags

      # Above `/tags/:id`, so that "suggestions" is not read as a tag name.
      get "/featured_tags/suggestions", API.FeaturedTagController, :suggestions
      get "/featured_tags", API.FeaturedTagController, :index
      post "/featured_tags", API.FeaturedTagController, :create
      delete "/featured_tags/:id", API.FeaturedTagController, :delete

      get "/tags/:id", API.InstanceInfoController, :show_tag
      post "/tags/:id/follow", API.InstanceInfoController, :follow_tag
      post "/tags/:id/unfollow", API.InstanceInfoController, :unfollow_tag
      post "/tags/:id/feature", API.InstanceInfoController, :feature_tag
      post "/tags/:id/unfeature", API.InstanceInfoController, :unfeature_tag

      get "/lists", API.ListController, :index
      post "/lists", API.ListController, :create
      get "/lists/:id", API.ListController, :show
      put "/lists/:id", API.ListController, :update
      delete "/lists/:id", API.ListController, :delete
      get "/lists/:id/accounts", API.ListController, :accounts
      post "/lists/:id/accounts", API.ListController, :add_accounts
      delete "/lists/:id/accounts", API.ListController, :remove_accounts

      get "/filters/keywords/:id", API.FilterController, :show_keyword
      put "/filters/keywords/:id", API.FilterController, :update_keyword
      delete "/filters/keywords/:id", API.FilterController, :delete_keyword
      get "/filters/statuses/:id", API.FilterController, :show_status
      delete "/filters/statuses/:id", API.FilterController, :delete_status

      get "/favourites", API.CollectionController, :favourites
      get "/bookmarks", API.CollectionController, :bookmarks
      get "/conversations", API.CollectionController, :conversations
      post "/conversations/:id/read", API.CollectionController, :read_conversation
      post "/conversations/:id/unread", API.CollectionController, :unread_conversation
      delete "/conversations/:id", API.CollectionController, :delete_conversation

      post "/media", API.MediaController, :create_v2

      get "/filters", API.FilterController, :index
      post "/filters", API.FilterController, :create
      get "/filters/:id", API.FilterController, :show
      put "/filters/:id", API.FilterController, :update
      # A Rails `resources` gives both verbs, so clients written against it use
      # whichever their HTTP library defaults to.
      patch "/filters/:id", API.FilterController, :update
      delete "/filters/:id", API.FilterController, :delete
      get "/filters/:filter_id/keywords", API.FilterController, :keywords
      post "/filters/:filter_id/keywords", API.FilterController, :add_keyword
      get "/filters/:filter_id/statuses", API.FilterController, :statuses
      post "/filters/:filter_id/statuses", API.FilterController, :add_status
      get "/suggestions", API.DirectoryController, :suggestions_v2
      get "/search", API.SearchController, :search
      # The v2 notification family. The fixed paths come before `/:group_key`,
      # or "policy" and "clear" are read as group keys.
      get "/notifications", API.NotificationController, :grouped_index
      get "/notifications/unread_count", API.NotificationController, :grouped_unread_count
      get "/notifications/policy", API.NotificationController, :get_policy
      put "/notifications/policy", API.NotificationController, :put_policy
      post "/notifications/clear", API.NotificationController, :clear
      get "/notifications/:group_key/accounts", API.NotificationController, :group_accounts
      post "/notifications/:group_key/dismiss", API.NotificationController, :dismiss_group
      get "/notifications/:group_key", API.NotificationController, :show_group
    end

    get "/api/v1/instance", InstanceController, :show_v1
  end

  scope "/", AbuubaWeb do
    pipe_through [:api, :app_registration]

    post "/api/v1/apps", AppController, :create
  end

  scope "/", AbuubaWeb do
    pipe_through [:api, :sign_up]

    post "/api/v1/accounts", API.AccountController, :create
    # The same budget as signing up, and for the same reason: this one sends
    # mail to an address a stranger chose.
    post "/api/v1/emails/confirmations", API.EmailController, :create
  end

  scope "/oauth", AbuubaWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :oauth,
      on_mount: [{AbuubaWeb.UserAuth, :ensure_authenticated}, AbuubaWeb.LocaleHook] do
      live "/authorize", AuthorizeLive
    end

    post "/authorize", OAuthAuthorizeController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:abuuba, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AbuubaWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end

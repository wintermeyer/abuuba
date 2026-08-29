defmodule AbuubaWeb.API.ScopeCoverageTest do
  @moduledoc """
  Every API route says what a token has to carry, or is listed here as one that
  deliberately does not.

  The reason this is a test rather than a convention: a scope declared per
  controller is a declaration somebody has to remember to write into the next
  one, and the endpoint that nobody declared is indistinguishable from a safe
  one until a token that should not have reached it does. The failure this
  catches is the whole of issue #190 in miniature, one route at a time.

  It reads the controller source rather than the compiled module because
  `Plug.Builder` compiles plug declarations into `call/2` and keeps nothing to
  ask at runtime. That makes it a lexical check: a scope declared in some way
  this does not recognise reads as no scope at all, which fails loudly and in
  the safe direction.
  """

  use ExUnit.Case, async: true

  @writes ~w(post put patch delete)a

  # Routes that answer without a token, on purpose. Each one is a decision, so
  # each one is written down with the reason it was made.
  @public [
    # Somebody who is usually not a member here asking to hear from an account.
    # Requiring a token would remove the only people the feature is for.
    {AbuubaWeb.API.EmailSubscriptionController, :create},
    # The server's own fundraising banner: the same for everybody signed in and
    # nothing of theirs.
    {AbuubaWeb.API.DonationCampaignController, :index}
  ]

  @scope_declaration ~r/plug AbuubaWeb\.Plugs\.RequireScopes,?\s+(?:\{:(?:when_authenticated|any),\s*)?\[[^\]]*\]\}?\s*when action in \[([^\]]*)\]/s
  @user_declaration ~r/plug AbuubaWeb\.Plugs\.RequireUser\b(?:\s*when action in \[([^\]]*)\])?/s

  test "every write route declares the scopes a token needs" do
    undeclared =
      for route <- api_routes(),
          route.verb in @writes,
          {route.plug, route.plug_opts} not in @public,
          not MapSet.member?(scoped(route.plug), route.plug_opts),
          do: "#{route.verb} #{route.path}"

    assert undeclared == [],
           """
           These write endpoints accept any live token:

           #{Enum.join(undeclared, "\n")}

           Declare what each needs with `plug AbuubaWeb.Plugs.RequireScopes,
           ["write:something"] when action in [...]`, or add it to @public in
           this file with the reason it takes none.
           """
  end

  test "every route behind a sign-in declares them too" do
    # A read is not automatically harmless. Somebody's own settings, their own
    # blocked servers and their own profile are all reads, and an app that only
    # asked for a timeline should not come back with any of them.
    undeclared =
      for route <- api_routes(),
          {route.plug, route.plug_opts} not in @public,
          private?(route.plug, route.plug_opts),
          not MapSet.member?(scoped(route.plug), route.plug_opts),
          do: "#{route.verb} #{route.path}"

    assert undeclared == [],
           """
           These endpoints need somebody signed in but take any scope:

           #{Enum.join(undeclared, "\n")}
           """
  end

  test "the reader recognises a declaration when it sees one" do
    # The positive control. Every assertion above passes just as happily when
    # the parser reads nothing at all, and a parser that quietly matched
    # nothing would report a fully declared API.
    assert MapSet.member?(scoped(AbuubaWeb.API.StatusController), :create)
    assert MapSet.member?(scoped(AbuubaWeb.API.StatusController), :index)
    refute MapSet.member?(scoped(AbuubaWeb.API.AccountController), :featured_tags)

    assert private?(AbuubaWeb.API.StatusController, :create)
    refute private?(AbuubaWeb.API.StatusController, :context)
    assert private?(AbuubaWeb.API.MediaController, :show)
  end

  ## Plumbing

  defp api_routes do
    Enum.filter(AbuubaWeb.Router.__routes__(), fn route ->
      is_atom(route.plug) and route.plug |> to_string() |> String.contains?("AbuubaWeb.API.")
    end)
  end

  defp scoped(controller) do
    @scope_declaration
    |> Regex.scan(source(controller))
    |> Enum.flat_map(fn [_match, actions] -> actions(actions) end)
    |> MapSet.new()
  end

  defp private?(controller, action) do
    src = source(controller)

    @user_declaration
    |> Regex.scan(src)
    |> Enum.any?(fn
      # No `when`: the plug covers every action in the controller.
      [_match] -> true
      [_match, actions] -> action in actions(actions)
    end)
  end

  defp actions(list) do
    ~r/:([a-z_0-9]+)/
    |> Regex.scan(list)
    |> Enum.map(fn [_match, name] -> String.to_existing_atom(name) end)
  end

  defp source(controller) do
    # Loaded first so that `String.to_existing_atom/1` below can be used at
    # all: an action name is an atom because it is a function in this module,
    # and until the module is loaded it may be an atom nothing has created.
    # Without this the parse raises or not depending on what else the suite
    # happened to run first.
    Code.ensure_loaded!(controller)

    name = controller |> Module.split() |> List.last() |> Macro.underscore()

    File.read!(Path.join("lib/abuuba_web/controllers/api", name <> ".ex"))
  end
end

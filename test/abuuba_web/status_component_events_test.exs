defmodule AbuubaWeb.StatusComponentEventsTest do
  @moduledoc """
  Every screen that draws a post answers every button on it.

  `AbuubaWeb.StatusComponent` draws one action bar wherever a post appears, and
  the events it raises go to whichever LiveView is rendering it. A screen that
  does not answer one swallows the click in its catch-all
  `handle_event(_event, _params, socket)`: nothing is written, nothing is
  drawn, no error appears, and the button looks live. That is how favourite,
  boost and bookmark came to work on two screens of six, and then how vote,
  edit and translate each stayed dead on four or five after `PostActions` was
  written to stop exactly this.

  Read from the source rather than from behaviour on purpose. The alternative
  is a mount and a click per screen per event, which is thirty tests to say one
  thing, and the thing worth saying is a list-against-list comparison. It is
  the sweep from `CLAUDE.md` run on every commit instead of when somebody
  remembers.

  ## The screen list is found, not written down

  It used to be a literal list here, and the one screen missing from it was the
  one with the bug: notifications drew the whole bar and answered none of it,
  and this file said nothing because nobody had added it. So the screens are
  now every LiveView that renders the component, and a new one is covered the
  day it is written.
  """
  use ExUnit.Case, async: true

  alias AbuubaWeb.PostActions

  @component "lib/abuuba_web/components/status_component.ex"
  @live_dir "lib/abuuba_web/live"

  defp events_raised do
    @component
    |> File.read!()
    |> then(&Regex.scan(~r/phx-(?:click|submit)="([a-z_]+)"/, &1))
    |> Enum.map(fn [_whole, event] -> event end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Every LiveView that draws a post, whatever it is called.
  defp screens do
    @live_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.map(&Path.join(@live_dir, &1))
    |> Enum.filter(&(&1 |> File.read!() |> String.contains?("<.status")))
    |> Enum.sort()
  end

  # Three honest answers, and nothing else counts. Either the screen attaches
  # the shared wiring — and only for the events that wiring actually answers,
  # which `PostActions.answers/0` states and the test below holds it to — or it
  # answers the event itself, or it does not draw the controls at all.
  defp answers?(source, event) do
    (String.contains?(source, "PostActions.attach(") and event in PostActions.answers()) or
      String.contains?(source, ~s|handle_event("#{event}"|) or
      (event in ~w(favourite boost bookmark) and String.contains?(source, "@post_actions"))
  end

  # Scoped to the render it sits on, not to the file. `interactive={false}`
  # anywhere would otherwise excuse a whole screen from the sweep, which is the
  # unscoped-exemption shape: the day a screen draws one inert post beside live
  # ones, it would leave this check silently. A screen is exempt only when
  # every post it draws is inert.
  defp interactive?(source) do
    ~r/<\.status\b[^>]*?\/>/s
    |> Regex.scan(source)
    |> Enum.map(fn [tag] -> tag end)
    |> Enum.any?(&(not String.contains?(&1, "interactive={false}")))
  end

  test "the shared wiring answers exactly what the component raises" do
    # The other half of `answers?/2` above. Attaching the hook is only a
    # truthful answer for as long as the hook answers everything, so the two
    # lists are compared rather than assumed to match.
    assert PostActions.answers() == events_raised()
  end

  test "the component raises the events this expects" do
    # A canary on the list itself. A new button added to the component makes
    # this fail before the per-screen check below can be trusted, because a
    # screen cannot answer an event nobody knew about.
    assert events_raised() == ~w(bookmark boost edit favourite reply translate vote)
  end

  test "every screen that draws a post is one this checked" do
    # The list is derived, so this is the canary on the derivation: if the
    # component is ever rendered through a wrapper and `<.status` stops
    # appearing in the screens, the sweep above would pass by finding nothing.
    found = Enum.map(screens(), &Path.basename/1)

    assert "home_live.ex" in found
    assert "notifications_live.ex" in found
    assert length(found) >= 6
  end

  test "every screen answers every event, or draws none of them" do
    failures =
      for path <- screens(),
          source = File.read!(path),
          interactive?(source),
          missing = Enum.reject(events_raised(), &answers?(source, &1)),
          missing != [],
          do: "#{path} never answers #{inspect(missing)}"

    assert failures == [],
           "These screens draw the action bar and swallow the clicks in a catch-all, so the " <>
             "buttons look live and do nothing:\n" <> Enum.join(failures, "\n")
  end
end

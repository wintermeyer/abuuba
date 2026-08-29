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
  """
  use ExUnit.Case, async: true

  @component "lib/abuuba_web/components/status_component.ex"

  # The screens that render the component. `landing_live` is deliberately not
  # here: it draws posts with `interactive: false`, which is the other half of
  # the same rule -- a control that cannot work on a screen is not drawn on it.
  @screens ~w(
    home_live
    profile_live
    tag_live
    search_live
    explore_live
    status_live
  )

  defp events_raised do
    @component
    |> File.read!()
    |> then(&Regex.scan(~r/phx-(?:click|submit)="([a-z_]+)"/, &1))
    |> Enum.map(fn [_whole, event] -> event end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp answers?(source, event) do
    String.contains?(source, ~s|handle_event("#{event}"|) or
      (event in ~w(favourite boost bookmark) and String.contains?(source, "@post_actions"))
  end

  test "the component raises the events this expects" do
    # A canary on the list itself. A new button added to the component makes
    # this fail before the per-screen check below can be trusted, because a
    # screen cannot answer an event nobody knew about.
    assert events_raised() == ~w(bookmark boost edit favourite reply translate vote)
  end

  for screen <- @screens do
    test "#{screen} answers all of them" do
      path = "lib/abuuba_web/live/#{unquote(screen)}.ex"
      source = File.read!(path)

      missing = Enum.reject(events_raised(), &answers?(source, &1))

      assert missing == [],
             "#{path} draws the action bar but never answers #{inspect(missing)}. " <>
               "Its catch-all handle_event swallows them, so the buttons look live and do nothing."
    end
  end
end

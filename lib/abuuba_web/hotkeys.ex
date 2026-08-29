defmodule AbuubaWeb.Hotkeys do
  @moduledoc """
  Which key does what.

  Declared here rather than scattered through the JavaScript that binds them,
  so that the help page and the bindings cannot disagree. A shortcuts page
  listing a key that does nothing is worse than no page at all.

  Single keys rather than chords, which is what every reader-heavy interface
  settles on and what the client apps already use. Nothing is bound while a
  text box has focus, since somebody writing a post is typing letters and not
  issuing commands.
  """

  @shortcuts [
    %{keys: ["n"], action: "compose", description: "Start a new post"},
    %{keys: ["/"], action: "search", description: "Search"},
    %{keys: ["g", "h"], action: "goto_home", description: "Go to home"},
    %{keys: ["g", "n"], action: "goto_notifications", description: "Go to notifications"},
    %{keys: ["g", "e"], action: "goto_explore", description: "Go to explore"},
    %{keys: ["j"], action: "next", description: "Move to the next post"},
    %{keys: ["k"], action: "previous", description: "Move to the previous post"},
    %{keys: ["Enter"], action: "open", description: "Open the selected post"},
    %{keys: ["f"], action: "favourite", description: "Favourite the selected post"},
    %{keys: ["b"], action: "boost", description: "Boost the selected post"},
    %{keys: ["r"], action: "reply", description: "Reply to the selected post"},
    %{keys: ["?"], action: "help", description: "Show this page"},
    %{keys: ["Escape"], action: "dismiss", description: "Close what is open"}
  ]

  @doc """
  Every shortcut, in the order the help page lists them.
  """
  @spec all() :: [map()]
  def all, do: @shortcuts

  @doc """
  The shortcuts as the browser needs them: a map from a key sequence to an
  action name.
  """
  @spec bindings() :: map()
  def bindings, do: Map.new(@shortcuts, &{Enum.join(&1.keys, " "), &1.action})
end

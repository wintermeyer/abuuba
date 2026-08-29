defmodule AbuubaWeb.ScopeWords do
  @moduledoc """
  What a scope means, in words somebody can consent to.

  A scope string is not something a person can weigh. `write:statuses` says
  nothing to anybody who has not read the API documentation, and the screen
  that asks for consent is the last place to expect that of a reader.

  Shared by the two screens that have to say it: the sign-in screen, where
  somebody decides, and the list of apps in the settings, where they look back
  at what they decided. Those two saying it differently would be worse than
  either saying it badly — the second is where somebody checks the first, and a
  check that reads differently is not a check.
  """

  use Gettext, backend: AbuubaWeb.Gettext

  @doc """
  One scope, as a sentence.

  Anything without a wording falls back to the raw scope rather than being
  hidden, so a scope added without a line here is ugly rather than invisible.
  Invisible would mean a screen that lists what an app may do while quietly
  leaving something out.
  """
  @spec describe(String.t()) :: String.t()
  def describe("read"), do: gettext("Read everything you can see")
  def describe("write"), do: gettext("Post, edit and delete on your behalf")
  def describe("follow"), do: gettext("Follow, unfollow, block and mute people for you")
  def describe("push"), do: gettext("Send you push notifications")
  def describe("profile"), do: gettext("Read your profile details")
  def describe("read:statuses"), do: gettext("Read your posts and timelines")
  def describe("read:accounts"), do: gettext("Read profiles you can see")
  def describe("read:notifications"), do: gettext("Read your notifications")
  def describe("read:blocks"), do: gettext("Read who you have blocked")
  def describe("read:bookmarks"), do: gettext("Read your bookmarks")
  def describe("read:favourites"), do: gettext("Read what you have favourited")
  def describe("read:filters"), do: gettext("Read your filters")
  def describe("read:follows"), do: gettext("Read who you follow")
  def describe("read:lists"), do: gettext("Read your lists")
  def describe("read:mutes"), do: gettext("Read who you have muted")
  def describe("read:search"), do: gettext("Search as you")
  def describe("write:statuses"), do: gettext("Post, edit and delete posts as you")
  def describe("write:media"), do: gettext("Upload files as you")
  def describe("write:accounts"), do: gettext("Change your profile")
  def describe("write:blocks"), do: gettext("Block and unblock people for you")
  def describe("write:bookmarks"), do: gettext("Bookmark posts for you")
  def describe("write:favourites"), do: gettext("Favourite posts as you")
  def describe("write:filters"), do: gettext("Change your filters")
  def describe("write:follows"), do: gettext("Follow and unfollow people for you")
  def describe("write:lists"), do: gettext("Change your lists")
  def describe("write:mutes"), do: gettext("Mute and unmute people for you")
  def describe("write:notifications"), do: gettext("Clear your notifications")
  def describe("write:reports"), do: gettext("File reports as you")
  def describe("write:conversations"), do: gettext("Mark your conversations as read")

  def describe("admin:" <> _rest = scope),
    do: gettext("Act as a moderator (%{scope})", scope: scope)

  def describe(scope), do: scope

  @doc """
  A set of scopes, each as a sentence, in the order they are given.

  Sorted and without repeats, because the caller is usually merging what
  several tokens carry and "read:statuses" twice is one thing an app may do.
  """
  @spec describe_all([String.t()]) :: [String.t()]
  def describe_all(scopes) do
    scopes
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&describe/1)
  end
end

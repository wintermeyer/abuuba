defmodule Abuuba.Instance.UpdateCheck do
  @moduledoc """
  Whether a newer abuuba has been released.

  ## Off unless the admin turns it on

  Asking a third party whether this server is up to date tells that third party
  that this server exists, roughly when it was last restarted, and what it is
  running. That is a small thing to hand over and a real one, and it should be
  a decision somebody made rather than a default they discover.

  So it is off, and the screen says in as many words what is sent and to whom
  before anybody turns it on.

  ## What is sent

  An ordinary HTTPS GET to the releases endpoint, with no query, no
  identifier, and nothing about this server in the body — there is no body.
  What the other end can see is what any web request shows: an IP address, a
  user agent, and the fact that somebody asked. Nothing about the accounts
  here, their number, or their posts is sent, and there is nowhere in the
  request for it to go.
  """

  alias Abuuba.Federation.HTTP
  alias Abuuba.Settings

  @cache_key :update_check
  @cache_ttl_ms :timer.hours(6)

  @doc """
  Whether the admin has turned this on.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get("update_check") == true

  @doc """
  The version this server is running.
  """
  @spec current_version() :: String.t()
  def current_version do
    case :application.get_key(:abuuba, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "unknown"
    end
  end

  @doc """
  Where the check asks, so the screen can show it before anybody agrees.
  """
  @spec endpoint() :: String.t()
  def endpoint, do: to_string(Settings.get("update_check_url"))

  @doc """
  The latest released version, or `nil`.

  `nil` covers every reason there is no answer — turned off, unreachable,
  unexpected shape — because the screen says the same thing for all of them
  and none of them is the admin's problem to diagnose.
  """
  @spec latest_version() :: String.t() | nil
  def latest_version do
    if enabled?(), do: Abuuba.Cache.fetch(@cache_key, @cache_ttl_ms, &fetch/0)
  end

  @doc """
  Whether there is something newer than what is running.
  """
  @spec behind?() :: boolean()
  def behind? do
    with latest when is_binary(latest) <- latest_version(),
         {:ok, latest} <- Version.parse(String.trim_leading(latest, "v")),
         {:ok, current} <- Version.parse(current_version()) do
      Version.compare(latest, current) == :gt
    else
      _ -> false
    end
  end

  @doc """
  Forgets the cached answer, for an admin who has just updated.
  """
  @spec forget() :: :ok
  def forget, do: Abuuba.Cache.invalidate(@cache_key)

  # Through the ordinary outbound layer, so this inherits the SSRF guards and
  # timeouts rather than growing its own — the URL is a setting, and a setting
  # is a value from outside the program.
  defp fetch do
    # `get_rest_json/2` and not `get_json/2`: a release feed answers
    # `application/json`, which the ActivityPub fetch refuses, so this asked
    # and threw the answer away on every run for as long as it existed.
    case HTTP.get_rest_json(endpoint()) do
      {:ok, %{"tag_name" => tag}} when is_binary(tag) -> tag
      {:ok, %{"version" => version}} when is_binary(version) -> version
      _ -> nil
    end
  end
end

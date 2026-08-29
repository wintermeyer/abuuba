defmodule Abuuba.Moderation.Signup.Captcha do
  @moduledoc """
  An optional hCaptcha in front of registration and confirmation.

  Off unless a site key and a secret are configured, because a server that
  quietly required a puzzle nobody set up would refuse every sign-up with no
  explanation. When it is on, a missing or unreadable answer is a refusal:
  a check that cannot be made must not pass, or the puzzle is decoration.

  The HTTP call is passed in rather than hard-wired so a test never reaches the
  network, and so a deployment behind an egress proxy can point it elsewhere.
  """

  require Logger

  @endpoint "https://api.hcaptcha.com/siteverify"

  @doc """
  Whether this server asks for a captcha at all.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: site_key() != nil and secret() != nil

  @doc """
  The key a page needs to render the widget, or `nil`.
  """
  @spec site_key() :: String.t() | nil
  def site_key, do: present(config()[:site_key])

  @doc """
  Checks an answer.

  `:ok` when it passes, `{:error, reason}` otherwise. A server with no captcha
  configured answers `:ok` without asking anybody anything.
  """
  @spec verify(String.t() | nil, keyword()) :: :ok | {:error, atom()}
  def verify(response, opts \\ []) do
    cond do
      not enabled?() -> :ok
      is_nil(present(response)) -> {:error, :captcha_missing}
      true -> ask(response, opts)
    end
  end

  defp ask(response, opts) do
    post = Keyword.get(opts, :post, &post/2)

    case post.(@endpoint, %{"secret" => secret(), "response" => response}) do
      {:ok, %{"success" => true}} ->
        :ok

      {:ok, _body} ->
        {:error, :captcha_failed}

      {:error, reason} ->
        # A checker we cannot reach means the check cannot be made, and a check
        # that cannot be made must not pass.
        Logger.warning("captcha check could not be made: #{inspect(reason)}")

        {:error, :captcha_unavailable}
    end
  end

  defp post(url, form) do
    case Req.post(url, form: form, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, response} -> {:error, {:unexpected, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secret, do: present(config()[:secret])

  defp config, do: Application.get_env(:abuuba, __MODULE__, [])

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end

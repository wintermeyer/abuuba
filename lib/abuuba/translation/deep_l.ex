defmodule Abuuba.Translation.DeepL do
  @moduledoc """
  DeepL, which translates a batch in one request.

  Texts are sent as HTML (`tag_handling=html`), which is what makes the
  `translate="no"` spans around custom emoji do anything. Without it a
  shortcode comes back translated into something that no longer renders.

  ## Its refusals are specific, and so are ours

  456 is a quota that has run out and 429 is a rate limit, and they mean
  different things to whoever is waiting: one is "come back in a minute", the
  other is "this server has spent its allowance for the month". Collapsing them
  into "something went wrong" throws away the only useful part of the answer.
  """

  @behaviour Abuuba.Translation

  require Logger

  @free_host "https://api-free.deepl.com"
  @pro_host "https://api.deepl.com"

  @impl Abuuba.Translation
  def name, do: "DeepL"

  @impl Abuuba.Translation
  def translate(texts, source, target, opts) do
    body =
      %{
        "text" => texts,
        "target_lang" => String.upcase(to_string(target)),
        "tag_handling" => "html"
      }
      |> maybe_source(source)

    case request("/v2/translate", body, opts) do
      {:ok, %{"translations" => translations}} ->
        {:ok, Enum.map(translations, & &1["text"])}

      {:ok, _body} ->
        {:error, :unexpected_answer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Abuuba.Translation
  def languages(opts) do
    case request("/v2/languages", %{"type" => "target"}, opts) do
      {:ok, languages} when is_list(languages) ->
        targets = Enum.map(languages, &String.downcase(&1["language"]))

        # DeepL detects the source, so every language it knows can be
        # translated from. Reporting a matrix would be inventing a limit.
        {:ok, Map.new(targets, &{&1, targets -- [&1]})}

      _ ->
        {:error, :unexpected_answer}
    end
  end

  ## Inside

  defp maybe_source(body, nil), do: body
  defp maybe_source(body, ""), do: body

  defp maybe_source(body, source) do
    Map.put(
      body,
      "source_lang",
      source |> to_string() |> String.split("-") |> hd() |> String.upcase()
    )
  end

  defp request(path, body, opts) do
    transport = Keyword.get(opts, :transport, &send_request/1)

    request = %{
      method: :post,
      url: host() <> path,
      headers: %{
        "authorization" => "DeepL-Auth-Key #{api_key()}",
        "content-type" => "application/json"
      },
      body: body
    }

    case transport.(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, reason_for(status)}
      {:error, reason} -> {:error, transport_reason(reason)}
    end
  end

  defp send_request(%{method: method, url: url, headers: headers, body: body}) do
    Req.request(
      method: method,
      url: url,
      headers: headers,
      json: body,
      receive_timeout: 10_000,
      retry: false
    )
  end

  # 456 is DeepL's own, and it is the one an admin has to act on.
  defp reason_for(456), do: :quota_exceeded
  defp reason_for(429), do: :rate_limited
  defp reason_for(status) when status in [401, 403], do: :unauthorised
  defp reason_for(status) when status in 500..599, do: :provider_unavailable
  defp reason_for(_status), do: :provider_error

  defp transport_reason(reason) do
    Logger.warning("translation request failed: #{inspect(reason)}")

    :provider_unavailable
  end

  # A free key ends in `:fx` and answers on a different host, which is the one
  # piece of DeepL configuration everybody gets wrong once.
  defp host do
    case config()[:host] do
      host when is_binary(host) and host != "" ->
        String.trim_trailing(host, "/")

      _ ->
        if String.ends_with?(to_string(api_key()), ":fx"), do: @free_host, else: @pro_host
    end
  end

  defp api_key, do: config()[:api_key]

  defp config, do: Application.get_env(:abuuba, __MODULE__, [])
end

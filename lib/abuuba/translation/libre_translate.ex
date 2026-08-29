defmodule Abuuba.Translation.LibreTranslate do
  @moduledoc """
  LibreTranslate, which anybody can run themselves.

  Its endpoint takes one text per request, so a batch is a series of them. That
  is worse than DeepL's shape and is the API it has; the batching above this
  module still matters, because the cache means the series happens once.

  `format=html` is what makes the `translate="no"` spans around custom emoji do
  anything.
  """

  @behaviour Abuuba.Translation

  require Logger

  @impl Abuuba.Translation
  def name, do: "LibreTranslate"

  @impl Abuuba.Translation
  def translate(texts, source, target, opts) do
    source = source |> to_string() |> String.split("-") |> hd()
    source = if source == "", do: "auto", else: source

    texts
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, acc} ->
      case translate_one(text, source, target, opts) do
        {:ok, translated} -> {:cont, {:ok, [translated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, translated} -> {:ok, Enum.reverse(translated)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Abuuba.Translation
  def languages(opts) do
    case request("/languages", nil, :get, opts) do
      {:ok, languages} when is_list(languages) ->
        {:ok,
         Map.new(languages, fn language ->
           {language["code"], language["targets"] || []}
         end)}

      _ ->
        {:error, :unexpected_answer}
    end
  end

  ## Inside

  defp translate_one(text, source, target, opts) do
    body =
      %{"q" => text, "source" => source, "target" => to_string(target), "format" => "html"}
      |> maybe_key()

    case request("/translate", body, :post, opts) do
      {:ok, %{"translatedText" => translated}} -> {:ok, translated}
      {:ok, _body} -> {:error, :unexpected_answer}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_key(body) do
    case config()[:api_key] do
      key when is_binary(key) and key != "" -> Map.put(body, "api_key", key)
      _ -> body
    end
  end

  defp request(path, body, method, opts) do
    transport = Keyword.get(opts, :transport, &send_request/1)

    request = %{
      method: method,
      url: endpoint() <> path,
      headers: %{"content-type" => "application/json"},
      body: body
    }

    case transport.(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, reason_for(status)}
      {:error, reason} -> {:error, transport_reason(reason)}
    end
  end

  defp send_request(%{method: method, url: url, headers: headers, body: body}) do
    options = [method: method, url: url, headers: headers, receive_timeout: 10_000, retry: false]

    Req.request(if(body, do: Keyword.put(options, :json, body), else: options))
  end

  defp reason_for(429), do: :rate_limited
  defp reason_for(status) when status in [401, 403], do: :unauthorised
  defp reason_for(status) when status in 500..599, do: :provider_unavailable
  defp reason_for(_status), do: :provider_error

  defp transport_reason(reason) do
    Logger.warning("translation request failed: #{inspect(reason)}")

    :provider_unavailable
  end

  defp endpoint do
    config()[:endpoint] |> to_string() |> String.trim_trailing("/")
  end

  defp config, do: Application.get_env(:abuuba, __MODULE__, [])
end

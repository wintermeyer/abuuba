defmodule AbuubaWeb.Streaming.Payload do
  @moduledoc """
  The envelope every streaming client reads.

  `{"stream": [...], "event": ..., "payload": ...}`, with the payload itself a
  **string** of JSON rather than an object. That looks like a mistake and is
  not: every existing client parses it twice, and sending an object instead
  makes them fail on the second parse.
  """

  @doc """
  Wraps a rendered entity in the envelope.
  """
  @spec envelope([String.t()], String.t(), term()) :: String.t()
  def envelope(streams, event, payload) do
    Jason.encode!(%{
      "stream" => streams,
      "event" => event,
      # Encoded twice on purpose. See the moduledoc.
      "payload" => encode_payload(payload)
    })
  end

  @doc """
  The same for an event that carries nothing.

  The key is left out rather than sent as null, because that is what the
  reference implementation emits and a client that parses the payload of every
  frame it receives would otherwise be handed a null to parse.
  """
  @spec envelope([String.t()], String.t()) :: String.t()
  def envelope(streams, event) do
    Jason.encode!(%{"stream" => streams, "event" => event})
  end

  @doc """
  Which scope a stream needs, or `nil` where it needs none.
  """
  @spec required_scope(String.t()) :: String.t() | nil
  def required_scope("user"), do: "read:statuses"
  def required_scope("user:notification"), do: "read:notifications"
  def required_scope("direct"), do: "read:statuses"
  def required_scope("list"), do: "read:lists"
  def required_scope(_stream), do: nil

  defp encode_payload(payload) when is_binary(payload), do: payload
  defp encode_payload(payload), do: Jason.encode!(payload)
end

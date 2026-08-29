defmodule Abuuba.Federation.HTTP.BodyLimit do
  @moduledoc """
  Stops reading a response once it is larger than the caller asked for.

  A ceiling applied after the fact is not a ceiling. Reading a body whole and
  trimming it to a megabyte still costs whatever the sender chose to send, and
  the sender is not always a peer somebody decided to federate with: a preview
  card is fetched from whatever address a stranger put in a post, and a remote
  picture from whatever address a peer put in an activity.

  So the body is streamed and the connection dropped at the ceiling. What
  arrives after that is the sender's own socket buffer draining, which costs
  this server nothing.
  """

  @doc """
  A collector for `Req`'s `:into`, halting once `max_bytes` have arrived.

  Returns exactly `max_bytes` when the body is longer, so that what a caller
  parses is the same either way.
  """
  @spec collect(pos_integer()) :: (term(), term() -> {:cont | :halt, term()})
  def collect(max_bytes) do
    fn {:data, data}, {req, resp} ->
      collected = (resp.body || "") <> data

      if byte_size(collected) >= max_bytes do
        {:halt, {req, %{resp | body: binary_part(collected, 0, max_bytes)}}}
      else
        {:cont, {req, %{resp | body: collected}}}
      end
    end
  end
end

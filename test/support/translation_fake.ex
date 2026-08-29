defmodule Abuuba.Translation.Fake do
  @moduledoc """
  A provider that answers from a function a test set.

  Kept in `test/support` rather than in the test file so it can be named in
  configuration the way a real provider is, which is the whole point: the
  behaviour is what a test is exercising.
  """

  @behaviour Abuuba.Translation

  @impl Abuuba.Translation
  def name, do: "Fake"

  @impl Abuuba.Translation
  def translate(texts, source, target, opts) do
    fun =
      :persistent_term.get({__MODULE__, :translate}, fn _t, _s, _target, _o -> {:ok, texts} end)

    fun.(texts, source, target, opts)
  end

  @impl Abuuba.Translation
  def languages(opts) do
    fun = :persistent_term.get({__MODULE__, :languages}, fn _opts -> {:ok, %{}} end)

    fun.(opts)
  end

  @doc "Sets what the next translation returns."
  def set(fun), do: :persistent_term.put({__MODULE__, :translate}, fun)

  @doc "Sets what the language list returns."
  def set_languages(fun), do: :persistent_term.put({__MODULE__, :languages}, fun)
end

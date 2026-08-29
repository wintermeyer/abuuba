defmodule Abuuba.Search.Query do
  @moduledoc """
  What somebody typed, after the operators have been read out of it.

  A struct rather than a map, so an adapter written later is handed something
  with a shape rather than something it has to guess at.
  """

  defstruct text: "", operators: %{}

  @typedoc "A parsed query."
  @type t :: %__MODULE__{text: String.t(), operators: map()}
end

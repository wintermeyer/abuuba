defmodule AbuubaWeb.RegistrationWords do
  @moduledoc """
  Whether somebody may sign up here, in a sentence.

  Shared by the two screens that say it: the front page a stranger arrives on,
  and the about page they click through to for the detail. The same server
  cannot describe its own door two ways, and it did — the wording lived twice,
  so editing one left the other saying the old thing with nothing to notice it.

  Follows `AbuubaWeb.ScopeWords` for the same reason it exists.
  """

  use Gettext, backend: AbuubaWeb.Gettext

  @doc """
  One registration mode, as a sentence.

  Anything without a wording answers with an empty string: a mode added without
  a line here should leave the paragraph out rather than draw an empty promise
  about who may join.
  """
  @spec note(atom()) :: String.t()
  def note(:open), do: gettext("Registration is open: anybody may sign up.")

  def note(:approved),
    do: gettext("Registration needs approval: you sign up and an admin reads your request.")

  def note(:closed),
    do: gettext("Registration is closed here, but any other server on the network will do.")

  def note(_mode), do: ""
end

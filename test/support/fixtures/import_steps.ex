defmodule Abuuba.ImportSteps do
  @moduledoc """
  Import steps that write nothing, for testing the machinery around them.

  The real steps need the whole source schema and most of a Mastodon database
  in it. A test about the runner, the report or the command wants neither, so
  it registers one of these instead:

      Application.put_env(:abuuba, :import_steps, [Abuuba.ImportSteps.Stub])

  `Abuuba.DataCase.with_steps/1` does that and puts the registered steps back
  afterwards.
  """

  defmodule Stub do
    @moduledoc "A step that succeeds at everything."

    @behaviour Abuuba.Importer.Step

    @impl Abuuba.Importer.Step
    def run(_opts), do: :ok

    @impl Abuuba.Importer.Step
    def check(_opts), do: []

    @impl Abuuba.Importer.Step
    def verify(_opts), do: [%{name: "stub", checked: 1, failures: []}]
  end

  defmodule Failing do
    @moduledoc "A step whose verification finds something, for the unhappy path."

    @behaviour Abuuba.Importer.Step

    @impl Abuuba.Importer.Step
    def run(_opts), do: :ok

    @impl Abuuba.Importer.Step
    def check(_opts), do: []

    @impl Abuuba.Importer.Step
    def verify(_opts), do: [%{name: "stub", checked: 1, failures: [%{id: 7}]}]
  end
end

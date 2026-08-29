defmodule Abuuba.Importer.Step do
  @moduledoc """
  What one part of a takeover has to be able to do.

  Steps are configuration: `config :abuuba, :import_steps, [...]` decides what an
  import runs. A behaviour is what makes that list checkable — a module in it
  that cannot do the job says so when the project compiles rather than in the
  middle of somebody's maintenance window.

  Three things, of which only the first is required:

    * `run/1` copies. It is called once and has to be safe to call again,
      because an interrupted import is continued rather than restarted.

    * `check/1` says what would stop it, before anything is written. It belongs
      here rather than inside `run/1` so that the dry run reports it: a
      precondition discovered after `--execute` is a precondition discovered
      too late.

    * `verify/1` proves the step afterwards, against the source, which is what
      makes `mix abuuba.import --verify` grow as steps are added instead of
      quietly narrowing to whatever the first step happened to check.
  """

  @typedoc "One thing standing in the way, as `Abuuba.Importer` reports it."
  @type problem :: %{key: String.t(), detail: String.t()}

  @typedoc """
  The result of one verification.

  `failures` names what differed rather than counting it, because "three
  accounts do not match" is not something anybody can act on.
  """
  @type verification :: %{
          name: String.t(),
          checked: non_neg_integer(),
          failures: [%{required(:id) => term(), optional(atom()) => term()}]
        }

  @callback run(keyword()) :: :ok | {:error, term()}
  @callback check(keyword()) :: [problem()]
  @callback verify(keyword()) :: [verification()]

  @optional_callbacks check: 1, verify: 1
end

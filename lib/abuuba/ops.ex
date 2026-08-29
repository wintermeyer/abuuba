defmodule Abuuba.Ops do
  @moduledoc """
  What the operational mix tasks have in common.

  ## Every destructive task can be asked what it would do

  `--dry-run` is not a convenience. These tasks are run on a live server, at
  the keyboard, usually by somebody who is already having a bad morning, and
  the difference between "delete media older than 30 days" and "…than 3 days"
  is one keystroke. A task that cannot be asked first is a task nobody should
  run.

  So the count comes from the same query the deletion uses. A dry run that
  counted differently from the real one would be worse than no dry run: it
  would be a number somebody trusted.

  ## Long ones say where they are

  A task that walks every account on the server and prints nothing for four
  minutes is a task somebody interrupts. Progress is written on one line so it
  does not fill a terminal, and the total is printed at the end whether or not
  anything was done — "0 removed" is an answer, and silence is not.
  """

  @doc """
  Starts the application the tasks need.

  The repo and nothing else where it can be helped: a mix task that boots the
  endpoint is a mix task that cannot be run on a machine already serving.
  """
  @spec start!() :: :ok
  def start! do
    Mix.Task.run("app.start")

    :ok
  end

  @doc """
  Whether `--dry-run` was passed.
  """
  @spec dry_run?(keyword()) :: boolean()
  def dry_run?(opts), do: Keyword.get(opts, :dry_run, false)

  @doc """
  Says what a run did, or would have done.

  One sentence, and it says "would" when nothing was written, because an
  operator scrolling back through a terminal should not have to remember which
  invocation had the flag on.
  """
  @spec report(boolean(), non_neg_integer(), String.t()) :: :ok
  def report(dry_run?, count, what) do
    plural = if count == 1, do: "", else: "s"

    # The verb agrees with the count, which "2 rows was affected" did not.
    verb =
      cond do
        dry_run? -> "would be"
        count == 1 -> "was"
        true -> "were"
      end

    Mix.shell().info("#{count} #{what}#{plural} #{verb} affected")
  end

  @doc """
  Writes progress on one line.

  Rewritten in place rather than a line per item: a task that walks a hundred
  thousand rows should not leave a hundred thousand lines behind it.
  """
  @spec progress(non_neg_integer(), non_neg_integer() | nil) :: :ok
  def progress(done, total \\ nil) do
    text = if total, do: "#{done}/#{total}", else: to_string(done)

    IO.write("\r  #{text}")
  end

  @doc """
  Ends a progress line, so the next thing printed starts on its own.
  """
  @spec progress_done() :: :ok
  def progress_done, do: IO.write("\n")

  @doc """
  Refuses politely rather than raising.
  """
  @spec unknown(String.t(), [String.t()]) :: no_return()
  def unknown(command, known) do
    Mix.raise("""
    Unknown command: #{command}

    Try one of: #{Enum.join(known, ", ")}
    """)
  end
end

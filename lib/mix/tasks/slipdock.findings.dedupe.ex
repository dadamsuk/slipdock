defmodule Mix.Tasks.Slipdock.Findings.Dedupe do
  @moduledoc """
  Collapses a board tree's open findings into one per lesson
  (`Slipdock.Findings.dedupe/2`, #1941): each card's repeats into its oldest,
  then each lesson repeated across cards, in the same words or reworded
  (`Slipdock.Findings.Lesson.alike?/2`), into the tree's oldest. Every repeat
  is merged, not deleted, so its count moves and a person can reopen it.

      mix slipdock.findings.dedupe slipdock --dry-run   # what it would merge
      mix slipdock.findings.dedupe slipdock             # merge them

  The board is an id, a code or a name. In a release, where there is no Mix:

      bin/slipdock rpc 'Slipdock.Findings.dedupe_named("slipdock", dry_run: true) |> IO.puts()'

  (W-1951 §Runbooks).
  """
  @shortdoc "Merges a board's repeated findings into one per lesson"

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [dry_run: :boolean])

    case args do
      [board] ->
        Mix.Task.run("app.start")

        case Slipdock.Findings.dedupe_named(board, dry_run: opts[:dry_run] == true) do
          {:error, message} -> Mix.raise(message)
          report -> Mix.shell().info(report)
        end

      _ ->
        Mix.raise("usage: mix slipdock.findings.dedupe BOARD [--dry-run]")
    end
  end
end

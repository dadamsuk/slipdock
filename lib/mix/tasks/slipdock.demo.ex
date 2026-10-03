defmodule Mix.Tasks.Slipdock.Demo do
  @shortdoc "Fills the database with a demo workspace"

  @moduledoc """
  Builds the demo workspace — two boards, an epic with subcards, a wiki, a
  scoring scheme and an automation — so a fresh install has something to look
  at and the screenshots in the README can be reproduced.

      mix slipdock.demo            # only if there are no boards yet
      mix slipdock.demo --force    # add it anyway, alongside what is there

  It makes three people with `example.com` addresses and leaves the boards
  owned by the first; sign in as that address to see them. Nothing is deleted
  — point `DATABASE_URL` at a throwaway database if you want it on its own.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [force: :boolean])

    case Slipdock.Demo.build(force: opts[:force]) do
      {:ok, board} ->
        Mix.shell().info("""
        Demo workspace built: “#{board.name}” (#{board.code}) and “Personal”.
        Sign in as #{Slipdock.Demo.owner_email()} to see them.
        """)

      {:error, :not_empty} ->
        Mix.shell().error(
          "There are boards here already — run with --force to add the demo anyway."
        )

        exit({:shutdown, 1})
    end
  end
end

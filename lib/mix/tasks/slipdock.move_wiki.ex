defmodule Mix.Tasks.Slipdock.MoveWiki do
  @shortdoc "Moves one board's wiki into a folder of another board (W-2201)"
  @moduledoc """
  Runs `Slipdock.Wiki.WikiMove` and prints its report.

      mix slipdock.move_wiki --user you@example.com --from job-promo --to kb \\
        --folder Jobs --dry-run

  Starts the Repo and PubSub only, so no jobs, mail or automations fire.
  `--dry-run` rolls back. Without it the changes are saved, so that takes
  `--apply`, and neither means the task refuses.
  """
  use Mix.Task

  @switches [
    user: :string,
    from: :string,
    to: :string,
    folder: :string,
    dry_run: :boolean,
    apply: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    if opts[:dry_run] == opts[:apply] or
         Enum.any?([:user, :from, :to, :folder], &is_nil(opts[&1])) do
      Mix.raise("say --user, --from, --to, --folder, and --dry-run or --apply")
    end

    Mix.Task.run("app.config")
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Slipdock.Repo.start_link(pool_size: 2, log: false)

    {:ok, _} =
      Phoenix.PubSub.Supervisor.start_link(name: Slipdock.PubSub, adapter: Phoenix.PubSub.PG2)

    case Slipdock.Wiki.WikiMove.run_named(opts[:user], opts[:from], opts[:to], opts[:folder],
           dry_run: opts[:dry_run] == true
         ) do
      {:ok, report} -> Mix.shell().info(inspect(report, pretty: true, limit: :infinity))
      {:error, reason} -> Mix.raise("nothing moved: #{inspect(reason)}")
    end
  end
end

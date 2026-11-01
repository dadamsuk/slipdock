defmodule Mix.Tasks.Slipdock.RootVault do
  @shortdoc "Moves vaults and pages to the one root vault (W-2201)"
  @moduledoc """
  Runs `Slipdock.Vaults.RootMigration` and writes a report.

      mix slipdock.root_vault --dry-run --out DIR [--rename kb=GMinds]
        [--keep-folder Handbook] [--keep-page W-1] [--user ID] [--no-model]

  Starts the Repo and PubSub only, so no jobs, mail or automations fire.
  `--dry-run` rolls back. Without it the changes are saved, so that takes
  `--apply`, and neither means the task refuses.
  """
  use Mix.Task

  alias Slipdock.Vaults.RootReport

  @switches [
    dry_run: :boolean,
    apply: :boolean,
    out: :string,
    rename: :keep,
    keep_folder: :keep,
    keep_page: :keep,
    user: :keep,
    model: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    if opts[:dry_run] == opts[:apply] or is_nil(opts[:out]) do
      Mix.raise("say --dry-run or --apply, and --out DIR")
    end

    Mix.Task.run("app.config")
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Slipdock.Repo.start_link(pool_size: 2, log: false)

    {:ok, _} =
      Phoenix.PubSub.Supervisor.start_link(name: Slipdock.PubSub, adapter: Phoenix.PubSub.PG2)

    result =
      Slipdock.Vaults.RootMigration.run_all(
        dry_run: opts[:dry_run] == true,
        model: opts[:model] != false,
        rename: renames(opts),
        keep_folders: Keyword.get_values(opts, :keep_folder),
        keep_pages: Keyword.get_values(opts, :keep_page),
        user_ids: user_ids(opts)
      )

    summary = RootReport.write(result, opts[:out])
    Mix.shell().info(inspect(summary, pretty: true, limit: :infinity))
  end

  defp renames(opts) do
    opts
    |> Keyword.get_values(:rename)
    |> Map.new(fn pair ->
      [code, name] = String.split(pair, "=", parts: 2)
      {code, name}
    end)
  end

  defp user_ids(opts) do
    case Keyword.get_values(opts, :user) do
      [] -> nil
      ids -> Enum.map(ids, &String.to_integer/1)
    end
  end
end

defmodule Slipdock.Release do
  @moduledoc """
  The handful of administrative jobs that have to work in a release, where
  there is no Mix and so no `mix slipdock.*` tasks — the Docker image above all.

  The container's entrypoint calls these:

      docker compose run --rm slipdock migrate
      docker compose run --rm slipdock ai-key you@example.com sk-or-…
      docker compose run --rm slipdock reindex

  Each starts only as much of the app as it needs. Migrations in normal
  operation are not run from here: a release migrates itself on boot (see
  `Slipdock.Application`), and this is for doing it by hand.
  """

  @app :slipdock
  @batch 20

  @doc "Runs any pending migrations against the configured database."
  def migrate do
    load()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls `repo` back to `version`. Only ever run this deliberately."
  def rollback(repo, version) do
    load()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  The release's `mix slipdock.ai_key`: with no arguments, who has a key (masked);
  with an email and a key, stores it; with an email and `--remove`, deletes it.
  """
  def ai_key(args \\ []) do
    start()

    case args do
      [] -> list_keys()
      [email, "--remove"] -> remove_key(email)
      [email, key] -> put_key(email, key)
      _ -> puts("Usage: ai-key [<email> <key> | <email> --remove]")
    end
  end

  @doc """
  The release's `mix slipdock.reindex`, in its plain form: walk every card and
  wiki page and embed what changed. The options the mix task takes (`--force`,
  `--dry-run`, `--stats`) are not here; this is the one that matters when you
  have just restored a database.
  """
  def reindex(_args \\ []) do
    start()
    alias Slipdock.Search

    if Slipdock.AI.Embeddings.configured?() do
      started = System.monotonic_time(:millisecond)

      totals =
        %{embedded: 0, unchanged: 0, removed: 0}
        |> walk("cards", Search.all_card_ids(), &Search.load_cards/1, &Search.index_cards/1)
        |> walk("wiki pages", Search.all_page_ids(), &Search.load_pages/1, &Search.index_pages/1)

      seconds = Float.round((System.monotonic_time(:millisecond) - started) / 1000, 1)

      puts(
        "Done in #{seconds}s. embedded: #{totals.embedded}, " <>
          "unchanged: #{totals.unchanged}, removed: #{totals.removed}"
      )
    else
      puts(
        "No OpenRouter key is available for unattended work, so nothing can be " <>
          "embedded. Set one for somebody (ai-key), and name them with " <>
          "SLIPDOCK_AI_SYSTEM_USER if more than one person has one."
      )
    end
  end

  # ── the small print ────────────────────────────────────────────────────

  defp walk(totals, what, ids, load, index) do
    total = length(ids)

    if total == 0 do
      totals
    else
      puts("Walking #{total} #{what}…")

      ids
      |> Enum.chunk_every(@batch)
      |> Enum.reduce(totals, fn batch, acc ->
        case batch |> load.() |> index.() do
          {:ok, counts} -> Map.merge(acc, counts, fn _k, a, b -> a + b end)
          {:error, reason} -> raise "Embedding failed: #{reason}"
        end
      end)
    end
  end

  defp list_keys do
    alias Slipdock.AI.Keys

    case Keys.all() do
      empty when empty == %{} ->
        puts("No keys stored (#{Keys.path()}).")

      keys ->
        puts("#{map_size(keys)} key(s) in #{Keys.path()}:")

        for {id, entry} <- keys do
          puts(
            "  #{entry.email || "user ##{id}"}  #{Keys.masked(entry.api_key)}  set #{entry.updated_at}"
          )
        end
    end

    puts(
      "Unattended work uses: #{Slipdock.AI.Keys.masked(Slipdock.AI.Keys.system_key()) || "no key"}"
    )
  end

  defp put_key(email, key) do
    with_user(email, fn user ->
      case Slipdock.AI.Keys.put(user, key) do
        :ok -> puts("Stored #{Slipdock.AI.Keys.masked(key)} for #{user.email}.")
        {:error, message} -> puts(message)
      end
    end)
  end

  defp remove_key(email) do
    with_user(email, fn user ->
      :ok = Slipdock.AI.Keys.delete(user)
      puts("Removed the key for #{user.email}.")
    end)
  end

  defp with_user(email, fun) do
    case Slipdock.Accounts.get_user_by_email(email) do
      nil -> puts("No user with the email #{email}. They must sign in once first.")
      user -> fun.(user)
    end
  end

  # `eval` runs without the app started, which is what migrations want; the
  # other jobs need the repo and the config, so they start it.
  defp load, do: Application.load(@app)

  defp start do
    {:ok, _} = Application.ensure_all_started(@app)
    :ok
  end

  defp repos do
    load()
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp puts(text), do: IO.puts(text)
end

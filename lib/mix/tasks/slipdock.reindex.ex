defmodule Mix.Tasks.Slipdock.Reindex do
  @moduledoc """
  Builds or repairs the semantic search index (see `Slipdock.Search`).

      mix slipdock.reindex            # walk every card and wiki page, embed what changed
      mix slipdock.reindex --force    # empty the index first and rebuild it
      mix slipdock.reindex --dry-run  # say what would be embedded, call nothing
      mix slipdock.reindex --stats    # what is indexed right now, and change nothing

  Run it once after the migration to fill the index, and again after
  changing `:embed_model` or `:embed_dimensions` — vectors from different
  models are not comparable, so a model change makes every row stale.

  Walking everything is the normal mode and is cheap: a chunk whose text and
  model are unchanged is skipped locally, without an API call. That makes the
  task self-healing — a comment whose embedding failed, a card half-indexed
  when the app stopped, a wiki page written before pages were indexed at all
  — repaired simply by running it.

  Needs `OPENROUTER_API_KEY`. Embedding the whole of a board this size costs
  a fraction of a penny.
  """
  @shortdoc "Builds or repairs the semantic search index"

  use Mix.Task

  alias Slipdock.Search

  @batch 20

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [force: :boolean, dry_run: :boolean, stats: :boolean],
        aliases: [f: :force, n: :dry_run]
      )

    Mix.Task.run("app.start")

    cond do
      opts[:stats] -> stats()
      opts[:dry_run] -> dry_run()
      true -> reindex(opts[:force])
    end
  end

  defp stats do
    s = Search.stats()

    Mix.shell().info("""
    Model:      #{s.model}#{if s.dimensions, do: " (#{s.dimensions} dimensions)", else: ""}
    Chunks:     #{s.chunks}
    Cards:      #{s.cards}
    Pages:      #{s.pages}
    Queued:     #{s.pending}
    """)
  end

  defp dry_run do
    cards = Search.all_card_ids()
    pages = Search.all_page_ids()

    Mix.shell().info(
      "#{length(cards)} cards and #{length(pages)} wiki pages would be walked with " <>
        "#{Slipdock.AI.Embeddings.model()}."
    )

    Mix.shell().info("Nothing was called; drop --dry-run to do it.")
  end

  defp reindex(force?) do
    unless Slipdock.AI.Embeddings.configured?() do
      Mix.raise("OPENROUTER_API_KEY is not set, so nothing can be embedded.")
    end

    if force? do
      cleared = Search.clear()
      Mix.shell().info("Cleared #{cleared} existing chunks.")
    end

    started = System.monotonic_time(:millisecond)

    totals =
      %{embedded: 0, unchanged: 0, removed: 0}
      |> walk("cards", Search.all_card_ids(), &Search.load_cards/1, &Search.index_cards/1)
      |> walk("wiki pages", Search.all_page_ids(), &Search.load_pages/1, &Search.index_pages/1)

    seconds = Float.round((System.monotonic_time(:millisecond) - started) / 1000, 1)

    Mix.shell().info("""

    Done in #{seconds}s.
      embedded:  #{totals.embedded}
      unchanged: #{totals.unchanged}
      removed:   #{totals.removed}
    """)
  end

  # Cards and pages walk identically: load a batch, embed what changed, say
  # where it got to. Separate passes only because they load differently.
  defp walk(totals, what, ids, load, index) do
    total = length(ids)

    if total == 0 do
      totals
    else
      Mix.shell().info("Walking #{total} #{what} with #{Slipdock.AI.Embeddings.model()}…")

      ids
      |> Enum.chunk_every(@batch)
      |> Enum.with_index(1)
      |> Enum.reduce(totals, fn {batch, n}, acc ->
        case batch |> load.() |> index.() do
          {:ok, counts} ->
            done = min(n * @batch, total)
            Mix.shell().info("  #{done}/#{total} — #{counts.embedded} embedded this batch")
            Map.merge(acc, counts, fn _k, a, b -> a + b end)

          {:error, reason} ->
            Mix.raise("Embedding failed: #{reason}")
        end
      end)
    end
  end
end

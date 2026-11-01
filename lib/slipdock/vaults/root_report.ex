defmodule Slipdock.Vaults.RootReport do
  @moduledoc """
  What `Slipdock.Vaults.RootMigration` did or would do, as files in a folder:
  the tree, the moves, the link rewrites (with any it could not verify), the
  renames, and a summary to set against W-2201's numbers.
  """

  @doc "Writes the report's files under `dir`, and answers with the summary."
  def write(result, dir) do
    File.mkdir_p!(dir)

    for report <- result.users, report.new_paths.pages != %{} do
      tag = "user-#{report.user_id}"
      write_tree(report, dir, tag)
      write_moves(report, dir, tag)
      write_card_pages(report, dir, tag)
      write_rewrites(report, dir, tag)
      write_titles(report, dir, tag)
    end

    summary = summary(result)
    File.write!(Path.join(dir, "summary.exs"), inspect(summary, pretty: true, limit: :infinity))
    summary
  end

  defp write_tree(report, dir, tag) do
    paths = Map.values(report.new_paths.pages) ++ Map.values(report.new_paths.files)
    File.write!(Path.join(dir, "#{tag}-tree.txt"), paths |> Enum.sort() |> Enum.join("\n"))
  end

  defp write_moves(report, dir, tag) do
    rows =
      for {id, new} <- report.new_paths.pages,
          old = report.old_paths.pages[id],
          old != new,
          do: "#{id}\t#{old}\t#{new}\n"

    File.write!(Path.join(dir, "#{tag}-renames.tsv"), Enum.sort(rows))
  end

  defp write_card_pages(report, dir, tag) do
    moved =
      Enum.map(report.moved.moved, &"#{&1.code}\t#{&1.from || "(no folder)"}\t#{&1.title}\n")

    kept =
      Enum.map(report.moved.kept, &"#{&1.code}\t#{&1.folder || "(no folder)"}\t#{&1.title}\n")

    File.write!(Path.join(dir, "#{tag}-card-pages.tsv"), moved)
    File.write!(Path.join(dir, "#{tag}-kept-pages.tsv"), kept)
  end

  defp write_rewrites(report, dir, tag) do
    rows =
      Enum.map(report.rewrites, fn r ->
        "#{inspect(r.source)}\t#{r.raw}\t#{r.rewrite || "(NOT VERIFIED, LEFT ALONE)"}\n"
      end)

    File.write!(Path.join(dir, "#{tag}-link-rewrites.tsv"), rows)
  end

  defp write_titles(report, dir, tag) do
    rows = Enum.map(report.titles, &"#{&1.page_id}\t#{&1.from}\t#{&1.to}\n")
    File.write!(Path.join(dir, "#{tag}-pass-logs.tsv"), rows)
  end

  @doc "The numbers: one map per person, and the short names."
  def summary(result) do
    %{
      dry_run: result.dry_run,
      short_names: result.short_names,
      users: Enum.map(result.users, &person/1)
    }
  end

  defp person(report) do
    paths = Map.values(report.new_paths.pages) ++ Map.values(report.new_paths.files)

    %{
      user: report.email,
      vault: report.vault,
      renamed: report.renamed,
      pages: map_size(report.new_paths.pages),
      files: map_size(report.new_paths.files),
      top_level: paths |> Enum.map(&hd(String.split(&1, "/"))) |> Enum.uniq() |> Enum.sort(),
      card_pages_moved: length(report.moved.moved),
      card_pages_moved_from: Enum.frequencies_by(report.moved.moved, &(&1.from || "(no folder)")),
      card_folders: report.moved.moved |> Enum.map(& &1.card_id) |> Enum.uniq() |> length(),
      pages_kept: length(report.moved.kept),
      cross_board_pins: report.moved.cross_board,
      second_pins: report.moved.second_pins,
      pinned_children: report.moved.children,
      pass_logs_renamed: length(report.titles),
      links_changed: length(report.rewrites),
      links_rewritten: Enum.count(report.rewrites, & &1.rewrite),
      links_not_verified: Enum.count(report.rewrites, &is_nil(&1.rewrite)),
      paths_over_200: Enum.count(paths, &(String.length(&1) > 200)),
      longest_path: paths |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end),
      check: Map.update!(report.check, :links_lost, &length/1)
    }
  end
end

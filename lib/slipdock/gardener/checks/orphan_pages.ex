defmodule Slipdock.Gardener.Checks.OrphanPages do
  @moduledoc """
  Wiki pages nothing leads to (W-1807): no live backlink, not pinned to
  anything, in no folder, and older than `days` (default 30). Templates,
  drafts, pages placed on a list, pages with pages beneath them and folder
  indexes (a page named like its folder, or index/README) are never
  orphans. A page that links to a card isn't either: it shows in that
  card's Docs.

  A page filed in a folder is found from the folder, which is why filing
  is one of the fixes. Tuned on a copy of the real board (#1086): 92 of its
  95 unlinked pages were runner logs filed in a "Loop logs" folder, each one
  noise as a suggestion.

  The fix archives it (it can be restored), or files it into one of the
  board's top folders.
  """
  @behaviour Slipdock.Gardener.Check

  import Ecto.Query

  alias Slipdock.Gardener.Checks.Cards
  alias Slipdock.Repo
  alias Slipdock.Wiki.{Folder, Link, Page}

  @impl true
  def key, do: "orphan_pages"
  @impl true
  def label, do: "Pages nothing links to"
  @impl true
  def defaults, do: %{"enabled" => true, "days" => 30}

  @index_titles ~w(index readme _index home)
  @max_folders 5

  @impl true
  def find(ctx, %{"days" => days}) do
    cutoff = DateTime.add(ctx.now, -days * 86_400)

    pages =
      from(p in Page,
        where: p.board_id in ^ctx.board_ids and is_nil(p.archived_at),
        where: p.template == false and p.status != "draft" and is_nil(p.column_id),
        where: is_nil(p.folder_id),
        where: p.inserted_at <= ^cutoff,
        select:
          struct(p, [:id, :title, :board_id, :folder_id, :parent_id, :inserted_at, :updated_at])
      )
      |> Repo.all()

    ids = Enum.map(pages, & &1.id)
    reached = reached(ids)
    parents = parents(ids)
    folders = folders(ctx.board_ids)

    for page <- pages,
        not MapSet.member?(reached, page.id),
        not MapSet.member?(parents, page.id),
        not index?(page, folders) do
      %{
        subject: %{"pages" => [page.id]},
        state: page.updated_at,
        proposal: [%{"op" => "archive", "page" => page.id}],
        alternatives: filing(page, folders),
        explanation:
          "“#{page.title}” has nothing linking to it and isn't pinned anywhere; written #{Cards.day(page.inserted_at)}"
      }
    end
  end

  # Pages something live leads to: a backlink from another page (its body,
  # or a comment on it) or from a card, a pin at either end, or a link out
  # to a card, which lists the page among the card's Docs.
  defp reached([]), do: MapSet.new()

  defp reached(ids) do
    incoming =
      from(l in Link,
        where: l.target_page_id in ^ids,
        left_join: p in Page,
        on: p.id == coalesce(l.page_id, l.source_page_id),
        left_join: c in Slipdock.Boards.Card,
        on: c.id == l.source_card_id,
        where:
          (not is_nil(p.id) and is_nil(p.archived_at) and p.id != l.target_page_id) or
            (not is_nil(c.id) and is_nil(c.archived_at)) or l.pinned,
        select: l.target_page_id
      )
      |> Repo.all()

    outgoing =
      from(l in Link,
        where: l.page_id in ^ids and (l.pinned or not is_nil(l.target_card_id)),
        select: l.page_id
      )
      |> Repo.all()

    MapSet.new(incoming ++ outgoing)
  end

  defp parents([]), do: MapSet.new()

  defp parents(ids) do
    from(p in Page,
      where: p.parent_id in ^ids and is_nil(p.archived_at),
      distinct: true,
      select: p.parent_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp folders(board_ids) do
    from(f in Folder, where: f.board_id in ^board_ids, order_by: [asc: f.position, asc: f.name])
    |> Repo.all()
  end

  defp index?(page, folders) do
    title = page.title |> String.trim() |> String.downcase()

    title in @index_titles or
      Enum.any?(folders, &(&1.id == page.folder_id and String.downcase(&1.name) == title))
  end

  defp filing(page, folders) do
    folders
    |> Enum.filter(&(&1.board_id == page.board_id and is_nil(&1.parent_id)))
    |> Enum.take(@max_folders)
    |> Map.new(
      &{"file into #{&1.name}", [%{"op" => "file_page", "page" => page.id, "folder" => &1.id}]}
    )
  end
end

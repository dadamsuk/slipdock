defmodule Slipdock.Wiki.Tree do
  @moduledoc """
  The wiki tree the way a browser draws it: one container's direct children
  at a time, as light rows, never a page's body (W-103 R11.1).

  A container is named by a ref:

    * `:root` — the top of the board's wiki: its top-level folders, then the
      pages and files filed in no folder;
    * `{:folder, id}` — a folder: the folders inside it, then the pages and
      files filed in it;
    * `{:page, id}` — a page: the pages that are part of it.

  The two axes are drawn the way the old, load-everything tree drew them (see
  `Slipdock.Wiki.Folder`): a page sits in the folder it is filed in, under
  its parent page when the parent is filed in the same folder, and at the
  top of its folder when its parent is filed elsewhere or is not shown (a
  draft the reader cannot see, an archived page while archived pages are
  hidden). So every page shows up exactly once, however the two disagree.

  Folders are few, so they are read whole, once a call; pages are read by
  container, and only the columns a row draws. Each row carries `count`, how
  many rows opening it would show, so a chevron is drawn only where there is
  something under it; a folder's row also carries `pages`, every page beneath
  it at any depth, for the number beside its name.

  Options, as `Slipdock.Wiki.list_pages/2` takes them:

    * `:status` — `"published"` to leave drafts out (a reader who cannot write
      never sees one); both by default
    * `:template` — `false` to leave template pages out; listed by default
    * `:archived` — `false` (the default) or `:all`
    * `:only` — a set of page ids, when a filter has already decided which
      pages are shown; anything else is left out
    * `:folders` — the board's folders, when the caller already has them
  """

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Folder, Folders, Page, WikiFile}

  @type ref :: :root | {:folder, pos_integer} | {:page, pos_integer}

  @page_fields [
    :id,
    :board_id,
    :title,
    :slug,
    :code,
    :status,
    :template,
    :archived_at,
    :parent_id,
    :folder_id,
    :position,
    :priority,
    :flags,
    :due_date,
    :completed,
    :inserted_at,
    :updated_at
  ]

  @doc """
  Reads a ref as a URL or an event carries it: `"root"` (or blank),
  `"folder:12"`, `"page:7"`. Anything else is `:error`.
  """
  def parse_ref(ref) when ref in [nil, "", "root", "folder:"], do: {:ok, :root}

  def parse_ref("folder:" <> id), do: parse_id(:folder, id)
  def parse_ref("page:" <> id), do: parse_id(:page, id)
  def parse_ref(_), do: :error

  defp parse_id(kind, id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, {kind, n}}
      _ -> :error
    end
  end

  @doc "A ref written back the way `parse_ref/1` reads it."
  def ref_key(:root), do: "root"
  def ref_key({kind, id}), do: "#{kind}:#{id}"

  @doc """
  The rows directly inside `ref` on `board`, in the order the tree draws
  them: folders first, then pages, then files.

  `{:error, :not_found}` for a folder or page that is not on this board, so a
  ref from one board's tree can never read another's.
  """
  def children(%Board{} = board, ref, opts \\ []) do
    folders = Keyword.get_lazy(opts, :folders, fn -> Folders.list(board) end)

    case container(board, ref, folders) do
      {:ok, {:folder, folder_id}} ->
        stats = stats(board, folders, opts)

        {:ok,
         folder_rows(folders, folder_id, stats) ++
           page_rows(top_pages(board, folder_id, opts), opts) ++
           file_rows(board, folder_id, opts)}

      {:ok, {:page, page}} ->
        {:ok, page_rows(child_pages(page, opts), opts)}

      error ->
        error
    end
  end

  # What a ref names, checked against the board. The root is the folder
  # nobody made, and is read as `{:folder, nil}` from here on.
  defp container(_board, :root, _folders), do: {:ok, {:folder, nil}}

  defp container(_board, {:folder, id}, folders) do
    if Enum.any?(folders, &(&1.id == id)),
      do: {:ok, {:folder, id}},
      else: {:error, :not_found}
  end

  defp container(%Board{id: board_id}, {:page, id}, _folders) do
    case Repo.one(from(p in Page, where: p.id == ^id and p.board_id == ^board_id, select: p)) do
      nil -> {:error, :not_found}
      page -> {:ok, {:page, page}}
    end
  end

  defp container(_board, _ref, _folders), do: {:error, :not_found}

  @doc """
  How many pages are shown on `board` under these options: what the count in
  the wiki's toolbar says.
  """
  def count(%Board{id: board_id}, opts \\ []) do
    from(p in Page, as: :page, where: p.board_id == ^board_id)
    |> where(^visible(opts, :page))
    |> Repo.aggregate(:count)
  end

  @doc """
  The containers to open to show `page`, outermost first: the folders it is
  filed under, then the pages above it in its own folder. What revealing a
  page in the tree opens (R11.7).
  """
  def path_to(%Page{} = page, folders \\ nil) do
    folders = folders || Folders.list(page.board_id)

    folder_path =
      case page.folder_id && Enum.find(folders, &(&1.id == page.folder_id)) do
        nil -> []
        folder -> folder_chain(folder, folders)
      end

    folder_path ++ Enum.map(page_chain(page), &{:page, &1})
  end

  @doc "The containers to open to show `folder`, itself included."
  def path_to_folder(%Folder{} = folder, folders \\ nil),
    do: folder_chain(folder, folders || Folders.list(folder.board_id))

  defp folder_chain(%Folder{} = folder, folders) do
    by_id = Map.new(folders, &{&1.id, &1})

    Stream.iterate(folder, &(&1.parent_id && by_id[&1.parent_id]))
    |> Enum.take_while(& &1)
    |> Enum.reverse()
    |> Enum.map(&{:folder, &1.id})
  end

  # The page's parents for as long as they are filed where it is: past that
  # the tree draws it at the top of its own folder.
  defp page_chain(%Page{parent_id: nil}), do: []

  defp page_chain(%Page{} = page) do
    page.parent_id
    |> Stream.unfold(fn
      nil ->
        nil

      id ->
        case Repo.one(
               from(p in Page, where: p.id == ^id, select: map(p, [:id, :parent_id, :folder_id]))
             ) do
          %{folder_id: folder_id} = up when folder_id == page.folder_id -> {up.id, up.parent_id}
          _ -> nil
        end
    end)
    |> Enum.take(50)
    |> Enum.reverse()
  end

  ## Rows ----------------------------------------------------------------------

  defp folder_rows(folders, parent_id, stats) do
    folders
    |> Enum.filter(&(&1.parent_id == parent_id))
    |> Enum.sort_by(&{&1.position, &1.name})
    |> Enum.map(fn folder ->
      %{
        kind: "folder",
        id: folder.id,
        board_id: folder.board_id,
        title: folder.name,
        slug: folder.slug,
        parent_id: folder.parent_id,
        count:
          Enum.count(folders, &(&1.parent_id == folder.id)) +
            Map.get(stats.top, folder.id, 0) + Map.get(stats.files, folder.id, 0),
        pages: Map.get(stats.totals, folder.id, 0)
      }
    end)
  end

  defp page_rows(pages, opts) do
    counts = child_counts(Enum.map(pages, & &1.id), opts)
    Enum.map(pages, &page_row(&1, Map.get(counts, &1.id, 0)))
  end

  @doc false
  def page_row(page, count) do
    %{
      kind: "page",
      id: page.id,
      board_id: page.board_id,
      title: page.title,
      slug: page.slug,
      code: page.code,
      parent_id: page.parent_id,
      folder_id: page.folder_id,
      count: count,
      draft: page.status == "draft",
      template: page.template,
      archived: not is_nil(page.archived_at),
      priority: page.priority,
      flags: page.flags || [],
      due: page.due_date,
      completed: page.completed,
      inserted_at: page.inserted_at,
      updated_at: page.updated_at
    }
  end

  defp file_rows(%Board{id: board_id}, folder_id, opts) do
    if opts[:only] do
      # A filter is narrowing pages; files answer none of its questions.
      []
    else
      from(f in WikiFile,
        where: f.board_id == ^board_id and is_nil(f.archived_at),
        order_by: [asc: f.name, asc: f.id],
        select: map(f, [:id, :board_id, :name, :content_type, :folder_id])
      )
      |> in_folder(folder_id)
      |> Repo.all()
      |> Enum.map(fn file ->
        %{
          kind: "file",
          id: file.id,
          board_id: file.board_id,
          title: file.name,
          content_type: file.content_type,
          folder_id: file.folder_id,
          count: 0
        }
      end)
    end
  end

  defp in_folder(query, nil), do: where(query, [x], is_nil(x.folder_id))
  defp in_folder(query, id), do: where(query, [x], x.folder_id == ^id)

  ## Queries -------------------------------------------------------------------

  # The pages at the top of a folder: filed there, with no parent drawn above
  # them in it. A parent filed elsewhere, or one the options hide, leaves the
  # page at the top rather than lost.
  defp top_query(board_id, opts) do
    from(p in Page,
      as: :page,
      left_join: up in Page,
      as: :up,
      on:
        up.id == p.parent_id and
          fragment("? IS NOT DISTINCT FROM ?", up.folder_id, p.folder_id),
      where: p.board_id == ^board_id
    )
    |> where(^visible(opts, :page))
    |> where(^hidden_parent(opts))
  end

  # The left join finds the parent when it is filed with the page; the page
  # is at the top when there is none, or the one there is would not be shown.
  defp hidden_parent(opts) do
    dynamic([up: up], is_nil(up.id) or not (^visible(opts, :up)))
  end

  defp top_pages(%Board{id: board_id}, folder_id, opts) do
    top_query(board_id, opts)
    |> in_folder(folder_id)
    |> order_by([page: p], asc: p.position, asc: p.title, asc: p.id)
    |> select([page: p], struct(p, ^@page_fields))
    |> Repo.all()
  end

  defp child_pages(%Page{} = parent, opts) do
    from(p in Page,
      as: :page,
      where: p.parent_id == ^parent.id,
      where: fragment("? IS NOT DISTINCT FROM ?", p.folder_id, ^parent.folder_id),
      order_by: [asc: p.position, asc: p.title, asc: p.id],
      select: struct(p, ^@page_fields)
    )
    |> where(^visible(opts, :page))
    |> Repo.all()
  end

  # How many shown pages are part of each of these, filed alongside it.
  defp child_counts([], _opts), do: %{}

  defp child_counts(ids, opts) do
    from(c in Page,
      as: :page,
      join: p in Page,
      on: p.id == c.parent_id,
      where: p.id in ^ids,
      where: fragment("? IS NOT DISTINCT FROM ?", c.folder_id, p.folder_id),
      group_by: p.id,
      select: {p.id, count(c.id)}
    )
    |> where(^visible(opts, :page))
    |> Repo.all()
    |> Map.new()
  end

  # Per folder, for its row: the pages at its top, its files, and every page
  # beneath it at any depth. Three grouped counts for the whole board.
  defp stats(%Board{id: board_id}, folders, opts) do
    direct =
      from(p in Page,
        as: :page,
        where: p.board_id == ^board_id and not is_nil(p.folder_id),
        group_by: p.folder_id,
        select: {p.folder_id, count(p.id)}
      )
      |> where(^visible(opts, :page))
      |> Repo.all()
      |> Map.new()

    top =
      top_query(board_id, opts)
      |> where([page: p], not is_nil(p.folder_id))
      |> group_by([page: p], p.folder_id)
      |> select([page: p], {p.folder_id, count(p.id)})
      |> Repo.all()
      |> Map.new()

    files =
      if opts[:only] do
        %{}
      else
        from(f in WikiFile,
          where: f.board_id == ^board_id and is_nil(f.archived_at) and not is_nil(f.folder_id),
          group_by: f.folder_id,
          select: {f.folder_id, count(f.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    %{top: top, files: files, totals: roll_up(folders, direct)}
  end

  # Every folder's pages and its subfolders' pages, from the direct counts.
  defp roll_up(folders, direct) do
    by_parent = Enum.group_by(folders, & &1.parent_id)

    total = fn total, id ->
      Map.get(direct, id, 0) +
        (by_parent |> Map.get(id, []) |> Enum.map(&total.(total, &1.id)) |> Enum.sum())
    end

    Map.new(folders, &{&1.id, total.(total, &1.id)})
  end

  # Which pages the options let through, for the page bound as `binding`.
  defp visible(opts, binding) do
    conditions =
      [
        archived_condition(Keyword.get(opts, :archived, false), binding),
        template_condition(Keyword.get(opts, :template), binding),
        status_condition(Keyword.get(opts, :status), binding),
        only_condition(Keyword.get(opts, :only), binding)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.reduce(conditions, dynamic(true), &dynamic(^&2 and ^&1))
  end

  defp archived_condition(:all, _b), do: nil
  defp archived_condition(true, b), do: dynamic([{^b, p}], not is_nil(p.archived_at))
  defp archived_condition(_false, b), do: dynamic([{^b, p}], is_nil(p.archived_at))

  defp template_condition(true, b), do: dynamic([{^b, p}], p.template)
  defp template_condition(false, b), do: dynamic([{^b, p}], not p.template)
  defp template_condition(_any, _b), do: nil

  defp status_condition(status, b) when status in ["draft", "published"],
    do: dynamic([{^b, p}], p.status == ^status)

  defp status_condition(_any, _b), do: nil

  defp only_condition(nil, _b), do: nil

  defp only_condition(ids, b) do
    ids = Enum.to_list(ids)
    dynamic([{^b, p}], p.id in ^ids)
  end
end

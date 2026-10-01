defmodule Slipdock.Wiki do
  @moduledoc """
  The Wiki context: Markdown pages belonging to a board, their tree, and the
  history of every save (see `docs/wiki.md`).

  A board is the space. A page inherits the board's permissions, raised by
  any grant on the page itself, and lives in a tree of pages — `parent_id`
  — independent of the board's cards.

  Two rules run through everything here:

    * **Every save writes a revision.** A page is never quietly overwritten
      and never hard-deleted (archive, except an owner's purge), so any state
      it has been in is recoverable. Consecutive saves by the same author
      within ten minutes collapse into one revision so history stays readable.
    * **A save may carry the hash it was based on.** If someone else has
      written in between, the save is refused with both bodies rather than
      applied on top — the failure mode of last-write-wins is invisible data
      loss, and two agents and a person may all be writing the same runbook.

  Mutations broadcast `{:wiki_changed, board_id}` on `"wiki:<board_id>"`, so
  an open page refreshes when someone else writes to it.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.{Activity, Attachment, Board, Card, Column, Tag}
  alias Slipdock.Search.Indexer
  alias Slipdock.Wiki.{Folder, Folders, Link, Links, Markup, Page, Query, Revision, Section}

  @pubsub Slipdock.PubSub

  # Consecutive saves by the same hand, this close together, are one edit.
  @collapse_seconds 600

  ## PubSub -------------------------------------------------------------------

  def subscribe(board_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(board_id))

  defp topic(board_id), do: "wiki:#{board_id}"

  defp broadcast(board_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(board_id), {:wiki_changed, board_id})
    :ok
  end

  @doc "Tells every open wiki on this board that something changed."
  def broadcast_board(board_id), do: broadcast(board_id)

  ## Reading ------------------------------------------------------------------

  # What a page needs loaded to be drawn where a card would be: the facets
  # associations, plus the card contents it now carries (see
  # `Slipdock.Boards.Owned`). A tile reads the checklist and the comment count
  # the same way for either, so an unloaded association is a crash rather
  # than a blank.
  @board_preloads [
    :tags,
    :assignee,
    :checklist_items,
    :comments,
    :urls,
    :status_updates,
    :votes,
    :field_values
  ]

  @doc "The associations a page needs to stand in a card's place."
  def board_preloads, do: @board_preloads

  @doc """
  Pages on a board, ordered as the tree reads them (siblings by position,
  then title).

  Options:

    * `:archived` — `false` (the default), `true` for the archived alone, or
      `:all`
    * `:template` — `true` for template pages alone, `false` to leave them
      out; both are listed by default
    * `:status` — `"draft"` or `"published"`; both by default
    * `:q` — a substring of the title or body
    * `:parent` — a page (or id) whose direct children to list, or `:root`
    * `:folder` — a folder (or id) whose pages to list, or `:none` for the
      pages filed nowhere
  """
  def list_pages(%Board{id: board_id}, opts \\ []) do
    from(p in Page,
      where: p.board_id == ^board_id,
      order_by: [asc: p.position, asc: p.title],
      preload: ^@board_preloads
    )
    |> filter_archived(Keyword.get(opts, :archived, false))
    |> filter_template(Keyword.get(opts, :template))
    |> filter_status(Keyword.get(opts, :status))
    |> filter_parent(Keyword.get(opts, :parent))
    |> filter_folder(Keyword.get(opts, :folder))
    |> filter_text(Keyword.get(opts, :q))
    |> Repo.all()
  end

  defp filter_archived(query, :all), do: query
  defp filter_archived(query, true), do: where(query, [p], not is_nil(p.archived_at))
  defp filter_archived(query, _false), do: where(query, [p], is_nil(p.archived_at))

  defp filter_template(query, nil), do: query
  defp filter_template(query, true), do: where(query, [p], p.template)
  defp filter_template(query, false), do: where(query, [p], not p.template)

  defp filter_status(query, status) when status in ["draft", "published"],
    do: where(query, [p], p.status == ^status)

  defp filter_status(query, _), do: query

  defp filter_parent(query, nil), do: query
  defp filter_parent(query, :root), do: where(query, [p], is_nil(p.parent_id))
  defp filter_parent(query, %Page{id: id}), do: where(query, [p], p.parent_id == ^id)
  defp filter_parent(query, id) when is_integer(id), do: where(query, [p], p.parent_id == ^id)

  defp filter_folder(query, nil), do: query
  defp filter_folder(query, :none), do: where(query, [p], is_nil(p.folder_id))
  defp filter_folder(query, %Folder{id: id}), do: where(query, [p], p.folder_id == ^id)
  defp filter_folder(query, id) when is_integer(id), do: where(query, [p], p.folder_id == ^id)

  defp filter_text(query, q) when is_binary(q) do
    case String.trim(q) do
      "" ->
        query

      term ->
        like = "%#{term}%"
        where(query, [p], like(p.title, ^like) or like(p.body, ^like))
    end
  end

  defp filter_text(query, _), do: query

  @doc """
  The board's pages as a tree: `[%{page: page, children: [...]}, ...]`.

  Takes the same options as `list_pages/2`. A page whose parent is filtered
  out (archived, say) comes back at the top rather than disappearing with it.
  """
  def tree(%Board{} = board, opts \\ []), do: board |> list_pages(opts) |> tree_from()

  @doc """
  The same tree, built from a list of pages you have already narrowed down.

  A page whose parent was filtered out stands at the root rather than
  vanishing with it — which is what someone filtering a tree means.
  """
  def tree_from(pages) when is_list(pages) do
    ids = MapSet.new(pages, & &1.id)
    by_parent = Enum.group_by(pages, fn p -> if p.parent_id in ids, do: p.parent_id end)
    build_tree(by_parent, nil)
  end

  defp build_tree(by_parent, parent_id) do
    by_parent
    |> Map.get(parent_id, [])
    |> Enum.map(&%{page: &1, children: build_tree(by_parent, &1.id)})
  end

  ## Folders -----------------------------------------------------------------

  # Filing, as opposed to the page tree, which is composition. See
  # `Slipdock.Wiki.Folder` for why the two are separate axes.

  @doc "Every folder on a board, in order."
  defdelegate folders(board), to: Folders, as: :list

  @doc """
  The board's folders flattened for a picker: each with its path and depth,
  in the order the sidebar draws them.
  """
  def folder_outline(board), do: board |> folders() |> Folders.outline()

  @doc "The board's folders as a tree, with `pages` filed into them."
  defdelegate folder_tree(board, pages), to: Folders, as: :tree

  @doc "The same tree, from folders already in hand — one query saved."
  defdelegate folder_tree_from(folders, pages), to: Folders, as: :tree_from

  @doc "The pages, of those given, filed in no folder."
  defdelegate unfiled(pages), to: Folders, as: :root

  @doc "Finds a folder on a board by id, slug, name or path."
  defdelegate find_folder(board, ref), to: Folders, as: :find

  @doc "A folder by id."
  defdelegate get_folder(id), to: Folders, as: :get

  @doc "Makes a folder (a name with slashes makes the whole path)."
  defdelegate create_folder(board, attrs), to: Folders, as: :create

  @doc "Renames, moves or reorders a folder."
  defdelegate update_folder(folder, attrs), to: Folders, as: :update

  @doc "Moves a folder under another and places it before `before` (nil: last)."
  defdelegate move_folder(folder, parent, before \\ nil), to: Folders, as: :move

  @doc """
  Deletes a folder: `:keep` (the default) keeps everything filed in it,
  `:purge` deletes the folders beneath it and every page in them.
  """
  defdelegate delete_folder(folder, strategy \\ :keep), to: Folders, as: :delete

  @doc "What purging a folder would take with it: `%{folders: n, pages: n}`."
  defdelegate folder_contents_count(folder), to: Folders, as: :contents_count

  @doc "Files a page in a folder, or takes it out of one with `nil`."
  defdelegate file_page(page, folder), to: Folders, as: :put_page

  @doc ~S'A folder written as it is addressed: "Design/Decisions".'
  defdelegate folder_path(folder), to: Folders, as: :path

  @doc "A folder's ancestors, outermost first."
  defdelegate folder_ancestors(folder), to: Folders, as: :ancestors

  @doc "The pages directly under this one, in order."
  def children(%Page{} = page) do
    from(p in Page,
      where: p.parent_id == ^page.id and is_nil(p.archived_at),
      order_by: [asc: p.position, asc: p.title]
    )
    |> Repo.all()
  end

  @doc "Every page beneath this one, however deep, nearest first."
  def descendants(%Page{} = page) do
    children =
      from(p in Page, where: p.parent_id == ^page.id, order_by: [asc: p.position, asc: p.title])
      |> Repo.all()

    children ++ Enum.flat_map(children, &descendants/1)
  end

  @doc "The page's ancestors, outermost first — the breadcrumb."
  def ancestors(%Page{parent_id: nil}), do: []

  def ancestors(%Page{parent_id: parent_id}) do
    case Repo.get(Page, parent_id) do
      nil -> []
      parent -> ancestors(parent) ++ [parent]
    end
  end

  def get_page(id), do: Repo.get(Page, id)
  def get_page!(id), do: Repo.get!(Page, id)

  @doc """
  Finds a page by any of the names it answers to: a numeric id, a code
  (`W-31`), or `board-code/slug`.

  This is what the API and the CLI resolve `:id` with, so an agent can write
  the handle it has rather than the one the system prefers.
  """
  def find_page(ref) when is_integer(ref), do: fetch(Repo.get(Page, ref))

  def find_page(ref) when is_binary(ref) do
    ref = String.trim(ref)

    cond do
      Page.code?(ref) ->
        fetch(Repo.get_by(Page, code: Page.normalize_code(ref)))

      String.contains?(ref, "/") ->
        [board_ref, slug] = String.split(ref, "/", parts: 2)

        case Boards.find_board(board_ref) do
          {:ok, board} -> find_page(board, slug)
          _ -> {:error, :not_found, "board #{inspect(board_ref)}"}
        end

      true ->
        case Integer.parse(ref) do
          {id, ""} -> fetch(Repo.get(Page, id))
          _ -> {:error, :not_found, "page #{inspect(ref)}"}
        end
    end
  end

  @doc """
  Finds a page on `board` by id, code, slug, or (case-insensitively) title.

  Title matching is what makes `[[Retry policy]]` work without anyone having
  to know the slug; it is deliberately last, so a page whose title happens to
  read like another page's slug never wins.
  """
  def find_page(%Board{id: board_id}, ref) do
    ref = ref |> to_string() |> String.trim()

    with nil <- by_id_on_board(board_id, ref),
         nil <- by_code_on_board(board_id, ref),
         nil <- Repo.get_by(Page, board_id: board_id, slug: Page.sanitize_slug(ref)),
         nil <- by_title(board_id, ref) do
      {:error, :not_found, "page #{inspect(ref)}"}
    else
      %Page{} = page -> {:ok, page}
    end
  end

  defp by_id_on_board(board_id, ref) do
    case Integer.parse(ref) do
      {id, ""} -> Repo.one(from(p in Page, where: p.id == ^id and p.board_id == ^board_id))
      _ -> nil
    end
  end

  defp by_code_on_board(board_id, ref) do
    if Page.code?(ref),
      do: Repo.get_by(Page, board_id: board_id, code: Page.normalize_code(ref)),
      else: nil
  end

  defp by_title(board_id, ref) do
    Repo.one(
      from(p in Page,
        where: p.board_id == ^board_id,
        where: fragment("lower(?) = lower(?)", p.title, ^ref),
        order_by: [asc: p.id],
        limit: 1
      )
    )
  end

  defp fetch(nil), do: {:error, :not_found, "page"}
  defp fetch(%Page{} = page), do: {:ok, page}

  @doc "The board a page belongs to."
  def board_of(%Page{board_id: board_id}), do: Repo.get!(Board, board_id)

  @doc """
  Whether a reader at `level` may see this page at all.

  Drafts are the one thing a reader's permission does not reach: a page is
  only half-written until its author says otherwise.
  """
  def visible?(%Page{} = page, level) do
    cond do
      not Slipdock.Access.can_read?(level) -> false
      Page.draft?(page) -> Slipdock.Access.can_write?(level)
      true -> true
    end
  end

  ## Writing ------------------------------------------------------------------

  @doc """
  Creates a page on `board`.

  `attrs` carries `title` (required), and optionally `body`, `summary`,
  `slug`, `status`, `template` and `parent_id`. The slug comes off the title
  when it is not given, and the code off the board's own counter.

  Options say who is writing, and are recorded on the first revision:
  `:user`, `:via` (see `Slipdock.Wiki.Revision`), `:agent`, `:message`.
  """
  def create_page(%Board{} = board, attrs, opts \\ []) do
    attrs = stringify(attrs)
    user = opts[:user]

    result =
      Repo.transaction(fn ->
        number = next_number(board)
        title = attrs["title"] || ""
        slug = attrs["slug"] || Page.slug_from_title(title, &slug_taken?(board.id, &1))

        changeset =
          %Page{
            board_id: board.id,
            number: number,
            code: next_code(),
            created_by_id: user && user.id,
            updated_by_id: user && user.id,
            content_hash: Page.hash(attrs["body"] || "")
          }
          |> Page.changeset(Map.put(attrs, "slug", slug))
          |> check_parent(board)

        case Repo.insert(changeset) do
          {:ok, page} ->
            {:ok, _} = write_revision(page, opts, force: true)
            log(board.id, page, "page_created", "wrote “#{page.title}”")
            page

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, page} <- result do
      Links.reconcile(page)
      # Semantic search keeps its own index of everything written (see
      # `Slipdock.Search`); the queue embeds a moment later so no save waits
      # on the model.
      Indexer.enqueue_page(page)
      # A page people kept linking to before anyone wrote it: the links that
      # were waiting for this title start working now.
      resolve_wanted(page)
      broadcast(board.id)
      {:ok, page}
    end
  end

  # How many pages this board has had: the page's own ordinal on it. Taken in
  # the insert's own transaction, so two pages written at once cannot share it.
  defp next_number(%Board{id: board_id}) do
    {1, _} = Repo.update_all(from(b in Board, where: b.id == ^board_id), inc: [page_seq: 1])
    Repo.one!(from(b in Board, where: b.id == ^board_id, select: b.page_seq))
  end

  # The code is global, not per board, because `[[W-31]]` and
  # `GET /api/pages/W-31` carry no board with them and still have to land on
  # one page. (docs/wiki.md wanted the board's own counter behind it; a
  # per-board counter cannot be globally unique, and resolving without a
  # board is the more useful half. The per-board ordinal survives as
  # `number`.) Taken in the same transaction as the insert.
  defp next_code do
    highest =
      from(p in Page,
        select: max(fragment("CAST(substr(?, 3) AS INTEGER)", p.code))
      )
      |> Repo.one()

    Page.code_for((highest || 0) + 1)
  end

  defp slug_taken?(board_id, slug) do
    Repo.exists?(from(p in Page, where: p.board_id == ^board_id and p.slug == ^slug))
  end

  @doc """
  Saves changes to a page.

  `attrs` may carry `title`, `body`, `summary`, `slug`, `status`, `template`
  and `parent_id`. Options are as `create_page/3`, plus:

    * `:base_hash` — the `content_hash` the edit was made against. When it no
      longer matches, nothing is written and the call returns
      `{:error, :conflict, %{content_hash:, title:, body:}}` — the page as it
      now stands, to merge against.

  Sending no `base_hash` is allowed and means last-write-wins; the revision
  written on the way past is what makes that recoverable rather than lost.
  """
  def update_page(%Page{} = page, attrs, opts \\ []) do
    attrs = stringify(attrs)
    user = opts[:user]

    # Always save against the row as it now stands, not the copy the caller
    # read: with a `base_hash` that is what it is checked against, and without
    # one it means an unsent field keeps the other writer's value rather than
    # being quietly rolled back to what this caller last saw.
    page = Repo.get!(Page, page.id)

    with :ok <- check_base_hash(page, opts[:base_hash]) do
      result =
        Repo.transaction(fn ->
          changeset =
            page
            |> Page.changeset(attrs)
            |> maybe_put(:updated_by_id, user && user.id)
            |> check_parent(Repo.get!(Board, page.board_id))
            |> check_cycle(page)

          case Repo.update(changeset) do
            {:ok, updated} ->
              if changed_content?(changeset) do
                {:ok, _} = write_revision(updated, opts)
                log(updated.board_id, updated, "page_updated", "edited “#{updated.title}”")
              end

              updated

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      with {:ok, updated} <- result do
        Links.reconcile(updated)
        Indexer.enqueue_page(updated)
        if renamed?(page, updated), do: resolve_wanted(updated)
        broadcast(updated.board_id)
        {:ok, updated}
      end
    end
  end

  defp check_base_hash(_page, nil), do: :ok
  defp check_base_hash(_page, ""), do: :ok

  defp check_base_hash(%Page{content_hash: hash} = page, base) do
    if String.downcase(String.trim(base)) == hash do
      :ok
    else
      {:error, :conflict, %{content_hash: page.content_hash, title: page.title, body: page.body}}
    end
  end

  # A revision is only worth writing when the words changed; moving a page or
  # marking it a template is not an edit of the document.
  defp changed_content?(changeset) do
    Enum.any?([:title, :body, :summary], &Map.has_key?(changeset.changes, &1))
  end

  defp maybe_put(changeset, _field, nil), do: changeset
  defp maybe_put(changeset, field, value), do: Ecto.Changeset.put_change(changeset, field, value)

  # A parent has to be a page on the same board: a tree that reaches across
  # boards would reach across permissions with it.
  defp check_parent(changeset, %Board{id: board_id}) do
    case Ecto.Changeset.get_field(changeset, :parent_id) do
      nil ->
        changeset

      parent_id ->
        if Repo.exists?(from(p in Page, where: p.id == ^parent_id and p.board_id == ^board_id)),
          do: changeset,
          else: Ecto.Changeset.add_error(changeset, :parent_id, "is not a page on this board")
    end
  end

  defp check_cycle(changeset, %Page{id: id}) do
    parent_id = Ecto.Changeset.get_field(changeset, :parent_id)

    cond do
      is_nil(parent_id) -> changeset
      parent_id == id -> Ecto.Changeset.add_error(changeset, :parent_id, "cannot be itself")
      ancestor?(id, parent_id) -> Ecto.Changeset.add_error(changeset, :parent_id, "is beneath it")
      true -> changeset
    end
  end

  # Whether `page_id` is somewhere above `of_id` in the tree.
  defp ancestor?(page_id, of_id) do
    case Repo.one(from(p in Page, where: p.id == ^of_id, select: p.parent_id)) do
      nil -> false
      ^page_id -> true
      parent_id -> ancestor?(page_id, parent_id)
    end
  end

  @doc """
  Reparents or reorders a page. `parent` is a page, an id, or nil for the
  top; `position` is an integer among the new siblings, or `:top` / `:bottom`.
  """
  def move_page(%Page{} = page, parent, position \\ :bottom, opts \\ []) do
    parent_id =
      case parent do
        %Page{id: id} -> id
        id when is_integer(id) -> id
        _ -> nil
      end

    with {:ok, moved} <- update_page(page, %{"parent_id" => parent_id}, opts) do
      repack(moved, position)
      log(moved.board_id, moved, "page_moved", "moved “#{moved.title}”")
      broadcast(moved.board_id)
      {:ok, Repo.get!(Page, moved.id)}
    end
  end

  defp repack(%Page{} = page, position) do
    siblings =
      from(p in Page,
        where: p.board_id == ^page.board_id,
        where: ^parent_clause(page.parent_id),
        where: p.id != ^page.id,
        order_by: [asc: p.position, asc: p.title],
        select: p.id
      )
      |> Repo.all()

    index =
      case position do
        :top -> 0
        :bottom -> length(siblings)
        n when is_integer(n) -> n |> max(0) |> min(length(siblings))
        _ -> length(siblings)
      end

    {before, rest} = Enum.split(siblings, index)

    (before ++ [page.id] ++ rest)
    |> Enum.with_index()
    |> Enum.each(fn {id, i} ->
      Repo.update_all(from(p in Page, where: p.id == ^id), set: [position: i])
    end)
  end

  defp parent_clause(nil), do: dynamic([p], is_nil(p.parent_id))
  defp parent_clause(id), do: dynamic([p], p.parent_id == ^id)

  @doc "Puts a page away. Its children go with it, as a card's subcards do."
  def archive_page(%Page{} = page) do
    at = DateTime.utc_now() |> DateTime.truncate(:second)
    ids = [page.id | Enum.map(descendants(page), & &1.id)]

    Repo.update_all(from(p in Page, where: p.id in ^ids), set: [archived_at: at])
    # An archived page is out of the index at once: leaving it searchable
    # while the queue settles is exactly the wrong way round.
    Enum.each(ids, &Indexer.forget_page/1)
    log(page.board_id, page, "page_archived", "archived “#{page.title}”")
    broadcast(page.board_id)
    {:ok, Repo.get!(Page, page.id)}
  end

  @doc "Brings an archived page back, along with everything under it."
  def unarchive_page(%Page{} = page) do
    ids = [page.id | Enum.map(descendants(page), & &1.id)]

    Repo.update_all(from(p in Page, where: p.id in ^ids), set: [archived_at: nil])
    Indexer.enqueue_pages(ids)
    log(page.board_id, page, "page_restored", "restored “#{page.title}”")
    broadcast(page.board_id)
    {:ok, Repo.get!(Page, page.id)}
  end

  @doc """
  Deletes a page and its history for good. Archiving is what everything else
  does; this is the owner's purge, and children are left behind at the top of
  the tree rather than going silently with it.
  """
  def delete_page(%Page{} = page) do
    board_id = page.board_id

    Repo.delete(page)
    |> case do
      {:ok, deleted} ->
        Indexer.forget_page(page.id)
        log(board_id, nil, "page_deleted", "deleted “#{page.title}”")
        broadcast(board_id)
        {:ok, deleted}

      other ->
        other
    end
  end

  def change_page(%Page{} = page, attrs \\ %{}), do: Page.changeset(page, attrs)

  ## History ------------------------------------------------------------------

  @doc "The page's revisions, newest first."
  def list_revisions(%Page{id: id}, limit \\ 100) do
    from(r in Revision,
      where: r.page_id == ^id,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit
    )
    |> Repo.all()
    |> Repo.preload(:author)
  end

  def get_revision(%Page{id: page_id}, id) do
    case Repo.one(from(r in Revision, where: r.id == ^id and r.page_id == ^page_id)) do
      nil -> {:error, :not_found, "revision"}
      revision -> {:ok, Repo.preload(revision, :author)}
    end
  end

  @doc "The revision immediately before this one, or nil."
  def previous_revision(%Revision{} = revision) do
    from(r in Revision,
      where: r.page_id == ^revision.page_id,
      where:
        r.inserted_at < ^revision.inserted_at or
          (r.inserted_at == ^revision.inserted_at and r.id < ^revision.id),
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Puts the page back to how a revision had it. This is itself a save, so it
  writes a revision of its own — nothing is ever removed from history.
  """
  def revert_page(%Page{} = page, %Revision{} = revision, opts \\ []) do
    message = opts[:message] || "reverted to the version of #{format_stamp(revision.inserted_at)}"

    update_page(
      page,
      %{"title" => revision.title, "body" => revision.body},
      Keyword.put(opts, :message, message)
    )
  end

  defp format_stamp(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y %H:%M")

  @doc """
  A line-by-line diff between two bodies, as
  `[{:eq | :del | :ins, [line]}, ...]` — what the history view renders and
  what `kanban page diff` prints.
  """
  def diff(old, new) do
    List.myers_difference(lines(old), lines(new))
  end

  defp lines(nil), do: []
  defp lines(text), do: String.split(text, "\n")

  # A revision is the state *after* a save, so the newest always matches the
  # page and reverting is just "take that snapshot". Consecutive saves by the
  # same hand within ten minutes overwrite one another rather than piling up:
  # an agent appending every few minutes should not bury the day's real edits.
  defp write_revision(%Page{} = page, opts, flags \\ []) do
    user = opts[:user]
    via = opts[:via] || "web"

    attrs = %{
      "page_id" => page.id,
      "title" => page.title,
      "body" => page.body,
      "summary" => opts[:message],
      "via" => via,
      "agent" => opts[:agent],
      "author_id" => user && user.id
    }

    last = if flags[:force], do: nil, else: latest_revision(page.id)

    case collapsible(last, user, via) do
      nil ->
        %Revision{} |> Revision.changeset(attrs) |> Repo.insert()

      %Revision{} = revision ->
        revision
        |> Revision.changeset(Map.update!(attrs, "summary", &(&1 || revision.summary)))
        |> Repo.update()
    end
  end

  defp latest_revision(page_id) do
    from(r in Revision,
      where: r.page_id == ^page_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp collapsible(nil, _user, _via), do: nil

  defp collapsible(%Revision{} = revision, user, via) do
    same_author = revision.author_id == (user && user.id)
    recent = DateTime.diff(DateTime.utc_now(), revision.inserted_at) <= @collapse_seconds

    if same_author and revision.via == via and recent, do: revision
  end

  ## Activity -----------------------------------------------------------------

  @doc "Activity entries about pages on a board, newest first."
  def list_activity(board_id, limit \\ 50) do
    from(a in Activity,
      where: a.board_id == ^board_id and not is_nil(a.page_id),
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp log(board_id, page, kind, message) do
    Repo.insert(%Activity{
      board_id: board_id,
      page_id: page && page.id,
      kind: kind,
      message: message
    })
  end

  ## Helpers ------------------------------------------------------------------

  # Attributes reach us as atoms from Elixir and strings from the wire.
  defp stringify(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  @doc "The user shown as a page's author, for listings that want a name."
  def author_name(%User{name: name, email: email}), do: name || email
  def author_name(_), do: nil

  ## Links --------------------------------------------------------------------

  defdelegate extract_links(body), to: Links, as: :extract
  defdelegate outgoing_links(page), to: Links, as: :outgoing

  @doc """
  Takes a page's relation to something off again — the opposite of pinning.

  A reference the prose actually makes is unpinned rather than removed: the
  page does mention it, and the next save would write the row back.
  """
  def unlink(%Page{} = page, target) do
    with {:ok, link} <- Links.unlink(page, target) do
      broadcast(page.board_id)
      {:ok, link}
    end
  end

  defdelegate backlinks(page, reader \\ nil), to: Links
  defdelegate wanted(board), to: Links
  defdelegate pages_for_card(card, reader \\ nil), to: Links, as: :for_card
  defdelegate members(board), to: Links
  defdelegate reconcile_links(page), to: Links, as: :reconcile

  @doc """
  Marks a page as *the* page for a card (or another page, board or view), or
  takes the mark off. `target` is `{:card, card}`, `{:page, page}`,
  `{:board, board}` or `{:view, view}`.
  """
  def pin(%Page{} = page, target, pinned \\ true) do
    with {:ok, link} <- Links.pin(page, target, pinned) do
      broadcast(page.board_id)
      {:ok, link}
    end
  end

  defp renamed?(%Page{} = before, %Page{} = now),
    do: before.title != now.title or before.slug != now.slug

  # Links written as words rather than ids resolve late, so writing (or
  # renaming) a page can bring other pages' links to life. Only the pages
  # holding a matching unresolved link are touched.
  defp resolve_wanted(%Page{} = page) do
    wanted = [page.title, page.slug, page.code] |> Enum.map(&String.downcase/1)

    from(l in Link,
      join: p in Page,
      on: p.id == l.page_id,
      where: p.board_id == ^page.board_id,
      where: l.kind == "page" and not l.resolved,
      select: {l.page_id, l.raw}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, raw} -> String.downcase(inner_of(raw)) in wanted end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.each(fn id ->
      case Repo.get(Page, id) do
        %Page{} = other -> Links.reconcile(other)
        _ -> :ok
      end
    end)
  end

  defp inner_of(raw) do
    raw
    |> String.trim_leading("[[")
    |> String.trim_trailing("]]")
    |> String.split("|", parts: 2)
    |> hd()
    |> String.trim()
  end

  ## Sections -----------------------------------------------------------------
  #
  # Addressing a page by heading is the primary write path for an agent: two
  # writers touching different sections do not conflict, and appending a
  # dated note under `## Log` can never clobber a paragraph.

  @doc "The text of one section of a page, heading included."
  def read_section(%Page{} = page, path) do
    case Section.read(page.body, path) do
      {:ok, text} -> {:ok, text}
      {:error, :not_found} -> {:error, :not_found, section_hint(page, path)}
    end
  end

  @doc "Every heading in a page, as paths — what a missed section lists back."
  def sections(%Page{} = page), do: Section.headings(page.body)

  @doc "Replaces one section of a page. Takes the same options as `update_page/3`."
  def replace_section(%Page{} = page, path, text, opts \\ []) do
    write_section(page, opts, fn body -> Section.replace(body, path, text) end, path)
  end

  @doc """
  Adds to the end of one section. The write that cannot conflict, so it takes
  no `base_hash` and never refuses.
  """
  def append_section(%Page{} = page, path, text, opts \\ []) do
    opts = Keyword.delete(opts, :base_hash)
    write_section(page, opts, fn body -> Section.append(body, path, text) end, path)
  end

  @doc "Adds to the end of the page."
  def append(%Page{} = page, text, opts \\ []) do
    opts = Keyword.delete(opts, :base_hash)
    current = Repo.get!(Page, page.id)
    update_page(current, %{"body" => Section.append(current.body, text)}, opts)
  end

  defp write_section(%Page{} = page, opts, fun, path) do
    current = Repo.get!(Page, page.id)

    case fun.(current.body) do
      {:ok, body} -> update_page(current, %{"body" => body}, opts)
      {:error, :not_found} -> {:error, :not_found, section_hint(current, path)}
    end
  end

  defp section_hint(%Page{} = page, path) do
    case sections(page) do
      [] -> "section #{inspect(path)} (this page has no headings)"
      headings -> "section #{inspect(path)} (try: #{Enum.map_join(headings, ", ", & &1.path)})"
    end
  end

  ## Templates ---------------------------------------------------------------
  #
  # A template is an ordinary page with `template: true`: it is not read as
  # content, it is copied. Bodies may carry the same `{{…}}` placeholders
  # automation actions use, so a runbook template can fill in the card, the
  # board and the date it was made from.

  @doc "The template pages on a board — starting points rather than content."
  def list_templates(%Board{} = board), do: list_pages(board, template: true)

  @doc """
  Makes a page from a template page.

  `values` fills `{{…}}` placeholders beyond the built-in ones; `opts` takes
  everything `create_page/3` does, plus `:title` (overriding the template's),
  `:parent`, `:folder` — where to file it — and `:card`, a card whose details
  the placeholders may use and which the new page is pinned to.
  """
  def create_from_template(%Board{} = board, %Page{} = template, values \\ %{}, opts \\ []) do
    bindings = bindings(board, opts[:card], values)

    attrs = %{
      "title" => opts[:title] || render_template(template.title, bindings),
      "body" => render_template(template.body, bindings),
      "summary" => render_template(template.summary, bindings),
      "parent_id" => parent_id(board, opts[:parent]),
      "folder_id" => folder_id(board, opts[:folder])
    }

    with {:ok, page} <-
           create_page(board, attrs, Keyword.drop(opts, [:title, :parent, :folder, :card])) do
      maybe_pin_to_card(page, opts[:card])
      {:ok, page}
    end
  end

  @doc """
  "Write it up": a page for a card, pre-titled, pinned to it, and pre-filled
  from a template when the board has one.

  The pin is the point. A page that explains a card is no use if the person
  looking at the card cannot see that it exists.
  """
  def create_page_from_card(%Card{} = card, opts \\ []) do
    board = Repo.get!(Board, card.board_id)
    opts = Keyword.put(opts, :card, card)

    case opts[:template] && find_template(board, opts[:template]) do
      %Page{} = template ->
        create_from_template(board, template, opts[:values] || %{}, opts)

      _ ->
        attrs = %{
          "title" => opts[:title] || card.title,
          "body" => default_writeup(card, opts[:body]),
          "summary" => opts[:summary],
          "parent_id" => parent_id(board, opts[:parent]),
          "folder_id" => folder_id(board, opts[:folder])
        }

        with {:ok, page} <-
               create_page(
                 board,
                 attrs,
                 Keyword.drop(opts, [
                   :title,
                   :parent,
                   :folder,
                   :card,
                   :template,
                   :values,
                   :body,
                   :summary
                 ])
               ) do
          maybe_pin_to_card(page, card)
          {:ok, page}
        end
    end
  end

  # A stub worth opening: what it is about, and a log to append to. The card
  # reference is a live chip, so it stays true when the card moves on.
  defp default_writeup(%Card{} = card, nil) do
    """
    Written up from ##{card.id}.

    ## What this is

    ## Log

    - #{Date.utc_today()} page created
    """
  end

  defp default_writeup(_card, body), do: body

  defp find_template(%Board{} = board, ref) do
    case find_page(board, ref) do
      {:ok, %Page{template: true} = page} -> page
      _ -> nil
    end
  end

  defp maybe_pin_to_card(_page, nil), do: :ok
  defp maybe_pin_to_card(%Page{} = page, %Card{} = card), do: pin(page, {:card, card})

  # A parent may be handed over as a page, an id, or the handle somebody
  # wrote in an automation rule or on the command line.
  defp parent_id(_board, %Page{id: id}), do: id
  defp parent_id(_board, id) when is_integer(id), do: id
  defp parent_id(_board, nil), do: nil

  defp parent_id(%Board{} = board, ref) when is_binary(ref) do
    case find_page(board, ref) do
      {:ok, %Page{id: id}} -> id
      _ -> nil
    end
  end

  defp parent_id(_board, _ref), do: nil

  # Where to file it. A name or a path that does not exist yet is made, the
  # way it is for a page written over the API: nobody should have to build
  # the filing cabinet in a separate call.
  defp folder_id(_board, nil), do: nil
  defp folder_id(_board, %Folder{id: id}), do: id
  defp folder_id(_board, id) when is_integer(id), do: id

  defp folder_id(%Board{} = board, ref) when is_binary(ref) do
    case find_folder(board, ref) do
      {:ok, %Folder{id: id}} ->
        id

      _ ->
        case create_folder(board, %{"name" => ref}) do
          {:ok, %Folder{id: id}} -> id
          _ -> nil
        end
    end
  end

  defp folder_id(_board, _ref), do: nil

  defp bindings(%Board{} = board, card, values) do
    base = Slipdock.Automations.Runner.variables(%{card: card, board: board})
    Map.merge(base, Map.new(values, fn {k, v} -> {to_string(k), v} end))
  end

  defp render_template(nil, _bindings), do: nil
  defp render_template(text, bindings), do: Slipdock.Automations.Runner.render(text, bindings)

  @doc false
  # Called when a board is made from a template that carries pages.
  def install_template_pages(%Board{} = board, %Slipdock.Boards.Template{} = template, owner_id) do
    user = owner_id && Repo.get(User, owner_id)
    bindings = bindings(board, nil, %{})

    for page <- Slipdock.Boards.Template.normalize_pages(template.pages || []) do
      create_page(
        board,
        %{
          "title" => render_template(page["title"], bindings),
          "body" => render_template(page["body"], bindings),
          "summary" => render_template(page["summary"], bindings),
          "template" => page["template"]
        },
        user: user,
        via: "web",
        message: "from the #{template.name} template"
      )
    end

    :ok
  end

  ## From a page to the work --------------------------------------------------

  @doc """
  Turns a passage of a page into a card, and writes the link into both ends.

  `selection` is the text somebody highlighted: its first line becomes the
  card's title and the rest its description, with a link back to the page.
  The page gets the card's number written in beside the passage, so the
  document says where the work went — and if the passage cannot be found
  verbatim (it was reflowed, or came from rendered HTML), the link is
  recorded anyway rather than lost.
  """
  def create_card_from_selection(%Page{} = page, %Column{} = column, selection, opts \\ []) do
    {title, rest} = split_selection(selection)

    description =
      [rest, "From [#{page.title}](#{url_for(page)})."]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    with {:ok, card} <-
           Boards.create_card(column, %{"title" => title, "description" => description}) do
      note_card_in_page(page, card, selection, opts)
      {:ok, card}
    end
  end

  defp split_selection(selection) do
    case selection |> to_string() |> String.trim() |> String.split("\n", parts: 2) do
      [line] -> {String.slice(line, 0, 200), nil}
      [line, rest] -> {String.slice(line, 0, 200), String.trim(rest)}
    end
  end

  defp note_card_in_page(%Page{} = page, %Card{} = card, selection, opts) do
    current = Repo.get!(Page, page.id)
    passage = selection |> to_string() |> String.trim()

    if passage != "" and String.contains?(current.body, passage) do
      body = String.replace(current.body, passage, passage <> " (##{card.id})", global: false)
      update_page(current, %{"body" => body}, Keyword.put_new(opts, :message, "made ##{card.id}"))
    else
      Links.record(current, {:card, card})
    end
  end

  defp url_for(%Page{} = page), do: "/boards/#{page.board_id}/wiki/#{page.slug}"

  ## On the board --------------------------------------------------------------
  #
  # A page can be put in a list and dragged about like a card. It is a second,
  # optional axis: the page keeps its place in the wiki tree either way, and
  # most pages are never placed. The ones that are tend to be the spec sitting
  # in "In Progress" beside the work it describes.

  @doc """
  Puts a page in a list, or moves it to another one.

  `before` says where in the list, and counts cards as well as pages: a page
  shares one position sequence with them, so it can sit between two cards
  rather than after all of them. It takes a ref (`{:card, 12}`,
  `{:page, 7}`), a bare card id, or the `"page-7"` form the board's
  drag-and-drop sends back; nil puts the page at the end.

  The list has to be on the page's own board. A board is the space, and a
  page that could be dropped onto another board's list would be in two places
  at once.
  """
  @spec place(Page.t(), Column.t() | integer, term) :: {:ok, Page.t()} | {:error, term}
  def place(%Page{} = page, column, before \\ nil) do
    with {:ok, column} <- placeable_column(page, column) do
      Boards.reorder({:page, page.id}, page.column_id, column.id, before)

      placed = Repo.get!(Page, page.id)

      if page.column_id != column.id do
        log(placed.board_id, placed, "page_placed", "put “#{placed.title}” in #{column.name}")
      end

      broadcast(placed.board_id)
      Boards.broadcast_tree(Boards.root_of_board(placed.board_id))
      {:ok, placed}
    end
  end

  @doc "Takes a page off the board. It stays exactly where it was in the wiki."
  @spec unplace(Page.t()) :: {:ok, Page.t()}
  def unplace(%Page{column_id: nil} = page), do: {:ok, page}

  def unplace(%Page{} = page) do
    column_id = page.column_id

    Repo.update_all(from(p in Page, where: p.id == ^page.id),
      set: [column_id: nil, board_position: 0]
    )

    # The list it left closes up behind it.
    Boards.repack_column(column_id)

    unplaced = Repo.get!(Page, page.id)
    log(unplaced.board_id, unplaced, "page_unplaced", "took “#{unplaced.title}” off the board")
    broadcast(unplaced.board_id)
    Boards.broadcast_tree(Boards.root_of_board(unplaced.board_id))
    {:ok, unplaced}
  end

  @doc "The pages placed in a list, in board order, ready for the board's views."
  def placed_in(column_id, opts \\ []) do
    from(p in Page,
      where: p.column_id == ^column_id and is_nil(p.archived_at),
      order_by: [asc: p.board_position, asc: p.id],
      preload: ^@board_preloads
    )
    |> filter_status(Keyword.get(opts, :status))
    |> Repo.all()
    |> Enum.map(&Page.for_board/1)
  end

  @doc """
  The pages placed anywhere on a board, keyed by the list they are in — what
  the board view asks for once rather than once per list.
  """
  def placed_on(%Board{id: board_id}, opts \\ []) do
    from(p in Page,
      where: p.board_id == ^board_id and not is_nil(p.column_id) and is_nil(p.archived_at),
      order_by: [asc: p.board_position, asc: p.id],
      preload: ^@board_preloads
    )
    |> filter_status(Keyword.get(opts, :status))
    |> Repo.all()
    |> Enum.map(&Page.for_board/1)
    |> Enum.group_by(& &1.column_id)
  end

  defp placeable_column(%Page{} = page, %Column{} = column), do: check_column(page, column)

  defp placeable_column(%Page{} = page, column_id) when is_integer(column_id) do
    case Repo.get(Column, column_id) do
      nil -> {:error, :not_found, "list #{column_id}"}
      column -> check_column(page, column)
    end
  end

  defp placeable_column(_page, _column), do: {:error, :not_found, "list"}

  defp check_column(%Page{board_id: board_id}, %Column{board_id: board_id} = column),
    do: {:ok, column}

  defp check_column(_page, %Column{} = column),
    do: {:error, :unprocessable_entity, "#{inspect(column.name)} is a list on another board"}

  ## Publishing ---------------------------------------------------------------

  @doc """
  Gives a page a public token, so anyone with the link can read it — the way
  a saved view can be published.

  The live queries in it are **answered now and the answers stored**. An
  anonymous request has nobody behind it to have permissions, so answering a
  query then would be a way to read private cards from the open web; card
  chips and page links degrade to plain text for the same reason. A published
  page is therefore a snapshot of its answers and a live copy of its prose:
  publishing again refreshes the answers.

  A draft cannot be published. Half an answer is not something to put on the
  open web.
  """
  def publish(%Page{} = page, opts \\ []) do
    cond do
      Page.draft?(page) ->
        {:error, :unprocessable_entity, "a draft cannot be published; publish the page first"}

      true ->
        token =
          page.public_token || :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

        page
        |> Ecto.Changeset.change(
          public_token: token,
          frozen: freeze(page, opts),
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
        |> Repo.update()
        |> case do
          {:ok, published} ->
            log(published.board_id, published, "page_published", "published “#{published.title}”")
            broadcast(published.board_id)
            {:ok, published}

          other ->
            other
        end
    end
  end

  @doc "Withdraws a page's public link, and the answers frozen with it."
  def unpublish(%Page{} = page) do
    page
    |> Ecto.Changeset.change(public_token: nil, frozen: nil, published_at: nil)
    |> Repo.update()
    |> case do
      {:ok, withdrawn} ->
        log(withdrawn.board_id, withdrawn, "page_unpublished", "withdrew “#{withdrawn.title}”")
        broadcast(withdrawn.board_id)
        {:ok, withdrawn}

      other ->
        other
    end
  end

  @doc "The published page with that token, with its board, or nil."
  def get_published(token) when is_binary(token) do
    case Repo.get_by(Page, public_token: token) do
      nil -> nil
      %Page{status: "draft"} -> nil
      %Page{archived_at: at} when not is_nil(at) -> nil
      page -> %{page | board: Repo.get!(Board, page.board_id)}
    end
  end

  def get_published(_), do: nil

  # Every block and inline expression in the body, answered as the publisher
  # and stored by the text that asked. `SlipdockWeb.Wiki.Renderer` reads this
  # back rather than asking again.
  defp freeze(%Page{} = page, opts) do
    board = Repo.get!(Board, page.board_id)
    context = %{board: board, reader: opts[:user], page: page, today: Date.utc_today()}

    Map.merge(frozen_blocks(page.body, context), frozen_inline(page.body, context))
  end

  defp frozen_blocks(body, context) do
    ~r/^[ \t]*(`{3,}|~{3,})[ \t]*kanban(?:-query)?[ \t]*\n(.*?)\n[ \t]*\1[ \t]*$/ms
    |> Regex.scan(to_string(body))
    |> Enum.reduce(%{}, fn [_whole, _fence, source], acc ->
      case Query.parse(source) do
        {:ok, query} ->
          case Query.run(query, context) do
            {:ok, result} -> Map.put(acc, String.trim(source), jsonable(result))
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp frozen_inline(body, context) do
    body
    |> to_string()
    |> Markup.refs()
    |> Enum.filter(&(&1.kind == :inline))
    |> Enum.reduce(%{}, fn ref, acc ->
      case Query.inline(ref.target, context) do
        {:ok, text} -> Map.put(acc, ref.target, text)
        :error -> acc
      end
    end)
  end

  # Frozen answers go through JSON, so they are reduced to the parts a
  # renderer needs and nothing that would not survive the round trip.
  defp jsonable(%{kind: :count} = result), do: %{"kind" => "count", "count" => result.count}

  defp jsonable(%{kind: :progress} = result),
    do: %{
      "kind" => "progress",
      "done" => result.done,
      "total" => result.total,
      "percent" => result.percent,
      "label" => result[:label]
    }

  defp jsonable(%{kind: :list} = result),
    do: %{
      "kind" => "list",
      "empty" => result[:empty],
      "cards" => Enum.map(result.cards, &card_stub/1)
    }

  defp jsonable(%{kind: :groups} = result),
    do: %{
      "kind" => "groups",
      "empty" => result[:empty],
      "groups" =>
        Enum.map(
          result.groups,
          &%{"label" => &1.label, "cards" => Enum.map(&1.cards, fn c -> card_stub(c) end)}
        )
    }

  defp jsonable(%{kind: :table} = result),
    do: %{
      "kind" => "table",
      "empty" => result[:empty],
      "headers" => result.headers,
      "keys" => result.keys,
      "rows" => Enum.map(result.rows, &%{"card" => card_stub(&1.card), "cells" => &1.cells})
    }

  defp jsonable(_result), do: %{"kind" => "unknown"}

  defp card_stub(%Card{} = card),
    do: %{
      "id" => card.id,
      "title" => card.title,
      "board_id" => card.board_id,
      "completed" => card.completed
    }

  ## Tags ---------------------------------------------------------------------

  @doc "Replaces a page's tags with the given list of the board tree's `%Tag{}`s."
  def set_tags(%Page{} = page, tags) when is_list(tags) do
    page
    |> Repo.preload(:tags)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:tags, tags)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        broadcast(page.board_id)
        {:ok, updated}

      other ->
        other
    end
  end

  @doc "The tags on a page."
  def tags(%Page{} = page), do: Repo.preload(page, :tags).tags

  @doc "Pages on `board` carrying a tag, by name or id."
  def pages_with_tag(%Board{} = board, %Tag{id: tag_id}) do
    from(p in Page,
      join: t in "page_tags",
      on: t.page_id == p.id,
      where: p.board_id == ^board.id and t.tag_id == ^tag_id,
      where: is_nil(p.archived_at),
      order_by: [asc: p.position, asc: p.title]
    )
    |> Repo.all()
  end

  ## Attachments --------------------------------------------------------------

  @doc """
  Attaches a file to a page — the same flow cards already have, so pasting an
  image into a page body works the way pasting one into a description does.
  """
  def add_attachment(%Page{} = page, meta, source) do
    Slipdock.Boards.store_attachment(%{page_id: page.id}, "pages/#{page.id}", meta, source)
    |> case do
      {:ok, attachment} ->
        broadcast(page.board_id)
        {:ok, attachment}

      other ->
        other
    end
  end

  @doc "The files attached to a page."
  def attachments(%Page{id: id}) do
    from(a in Attachment, where: a.page_id == ^id, order_by: [asc: a.inserted_at, asc: a.id])
    |> Repo.all()
  end
end

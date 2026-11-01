defmodule Slipdock.Wiki.WikiMove do
  @moduledoc """
  Moving one board's whole wiki into a folder of another board of the same
  person, as Employability Ideas' went into KnowledgeBase/Jobs (W-2201).

  Run deliberately (`mix slipdock.move_wiki`, or `Slipdock.Release.move_wiki/1`
  from a release), never on boot. One transaction: all of it or none of it.
  `dry_run: true` does all of it, reports, and rolls back.

    1. **Before anything moves**, every `[[link]]` in the person's page
       bodies, card descriptions and comments is resolved.
    2. **The folder** named `folder` at the top of `target` is made, or the
       one already there is used.
    3. **What moves:** every top-level folder of `source` with everything in
       it (`Slipdock.Wiki.FolderMove`), and every page at the top of its
       wiki with the pages under it (`Slipdock.Wiki.Move`), and the files at
       its top. Codes, history, comments and attachments go with them, and
       each is recorded as a change, so a synced client sees a move.
    4. **What stays:** the folder holding `source`'s card folders. A card's
       own pages live with the card (W-2201), on the card's board.
    5. **Links:** each one whose target has changed is rewritten to the
       target's path below its board's folder (`Jobs/Archive/Acme/Status`),
       which no board rename can break, and only saved if it resolves to the
       old target; failing that, the path with the board's folder. One that
       can't be verified is left alone and reported. Each rewrite of a page
       is a new revision ("migration: link rewrite"), so it can be undone.

  Running it twice changes nothing: the second time there is nothing left
  to move, and no link has changed.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Comment}
  alias Slipdock.Repo
  alias Slipdock.Vaults
  alias Slipdock.Vaults.Index
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Changes, Folder, FolderMove, Links, Move, Page, WikiFile}

  @doc """
  Moves `source`'s wiki into `folder` at the top of `target`, for `user`, who
  must own both. `{:ok, report}`, or `{:error, reason}` with nothing changed.

  The report: `%{dry_run:, folder:, folders: [%{name:, pages:, folders:,
  files:}], pages:, files:, stayed: [%{code:, title:}], links_checked:,
  rewrites: [%{source:, raw:, rewrite:}], unverified: [...]}`.
  """
  def run(%User{} = user, %Board{} = source, %Board{} = target, folder, opts \\ []) do
    with :ok <- check(user, source, target, folder) do
      Repo.transaction(
        fn ->
          case move(user, source, target, String.trim(folder)) do
            {:ok, report} ->
              report = Map.put(report, :dry_run, opts[:dry_run] == true)
              if opts[:dry_run], do: Repo.rollback({:dry_run, report}), else: report

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end,
        timeout: :infinity
      )
      |> case do
        {:ok, report} -> {:ok, report}
        {:error, {:dry_run, report}} -> {:ok, report}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  `run/5` by name, for a task or a release: the person by email, the boards
  by code. `{:error, reason}` for any that isn't there.
  """
  def run_named(email, source_code, target_code, folder, opts \\ []) do
    with %User{} = user <- Repo.get_by(User, email: email) || {:error, "no user #{email}"},
         %Board{} = source <- board(source_code),
         %Board{} = target <- board(target_code) do
      run(user, source, target, folder, opts)
    end
  end

  defp board(code), do: Repo.get_by(Board, code: code) || {:error, "no board #{code}"}

  defp check(_user, %Board{id: id}, %Board{id: id}, _folder),
    do: {:error, "the source and the target are the same board"}

  defp check(%User{id: user_id}, %Board{owner_id: s}, %Board{owner_id: t}, _folder)
       when s != user_id or t != user_id,
       do: {:error, "both boards must be yours"}

  defp check(_user, _source, _target, folder) do
    if String.trim(to_string(folder)) == "", do: {:error, "the folder needs a name"}, else: :ok
  end

  defp move(user, source, target, name) do
    vault = Vaults.root(user)
    sources = link_sources(vault)
    before = resolve_all(sources, vault)

    with {:ok, folder} <- folder(target, name),
         {:ok, moved} <- move_folders(user, source, target, folder),
         {:ok, pages} <- move_pages(user, source, target, folder) do
      files = move_files(source, target, folder)
      {rewrites, unverified} = rewrite_links(link_sources(vault), before, vault)

      {:ok,
       %{
         folder: "#{target.name}/#{folder.name}",
         folders: moved,
         pages: pages + Enum.sum(Enum.map(moved, & &1.pages)),
         files: files + Enum.sum(Enum.map(moved, & &1.files)),
         stayed: stayed(source),
         links_checked: before |> Map.values() |> Enum.map(&length(Enum.uniq(&1))) |> Enum.sum(),
         rewrites: rewrites,
         unverified: unverified
       }}
    end
  end

  # The folder at the top of `target`, case aside, or a new one.
  defp folder(target, name) do
    existing =
      Repo.one(
        from(f in Folder,
          where:
            f.board_id == ^target.id and is_nil(f.parent_id) and
              fragment("lower(?)", f.name) == ^String.downcase(name),
          limit: 1
        )
      )

    case existing do
      %Folder{} = folder -> {:ok, folder}
      nil -> Wiki.create_folder(target, %{"name" => name})
    end
  end

  # Every top-level folder but the one that holds card folders.
  defp move_folders(user, source, target, into) do
    holding_cards =
      from(f in Folder,
        where: f.board_id == ^source.id and not is_nil(f.card_id),
        select: f.parent_id
      )

    from(f in Folder,
      where:
        f.board_id == ^source.id and is_nil(f.parent_id) and f.id not in subquery(holding_cards),
      order_by: [asc: f.position, asc: f.id]
    )
    |> Repo.all()
    |> Enum.reduce_while({:ok, []}, fn folder, {:ok, acc} ->
      case FolderMove.to_board(folder, target, user, parent: into) do
        {:ok, %{report: report}} ->
          {:cont,
           {:ok,
            acc ++
              [
                %{
                  name: folder.name,
                  pages: report.pages,
                  folders: report.folders,
                  files: report.files
                }
              ]}}

        {:error, reason} ->
          {:halt, {:error, "#{folder.name}: #{inspect(reason)}"}}

        {:error, _kind, message} ->
          {:halt, {:error, "#{folder.name}: #{message}"}}
      end
    end)
  end

  # The pages at the top of the wiki; the pages under them go with them.
  defp move_pages(user, source, target, into) do
    from(p in Page,
      where:
        p.board_id == ^source.id and is_nil(p.folder_id) and is_nil(p.parent_id) and
          is_nil(p.archived_at),
      order_by: [asc: p.id]
    )
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn page, {:ok, n} ->
      case Move.to_board(page, target, into, user) do
        {:ok, _} -> {:cont, {:ok, n + 1 + length(Wiki.descendants(page))}}
        {:error, _kind, message} -> {:halt, {:error, "#{page.title}: #{message}"}}
        {:error, reason} -> {:halt, {:error, "#{page.title}: #{inspect(reason)}"}}
      end
    end)
  end

  # The files at the top of the wiki, as `FolderMove` moves a folder's.
  defp move_files(source, target, into) do
    files =
      Repo.all(from(f in WikiFile, where: f.board_id == ^source.id and is_nil(f.folder_id)))

    Enum.each(files, fn file ->
      file |> Ecto.Changeset.change(board_id: target.id, folder_id: into.id) |> Repo.update!()
      for board <- [source.id, target.id], do: Changes.record(board, "file", file.id)
    end)

    length(files)
  end

  defp stayed(source) do
    from(p in Page,
      where: p.board_id == ^source.id and is_nil(p.archived_at),
      order_by: [asc: p.id],
      select: %{code: p.code, title: p.title}
    )
    |> Repo.all()
  end

  ## Links -----------------------------------------------------------------------

  # Everywhere a [[link]] can be written on the person's boards, read afresh:
  # a page that has moved is on another board.
  defp link_sources(vault) do
    ids = Vaults.board_ids(vault)

    pages =
      from(p in Page,
        where: p.board_id in ^ids and is_nil(p.archived_at),
        select: {p.id, p.board_id, p.body}
      )
      |> Repo.all()
      |> Enum.map(fn {id, board, body} -> {{:page, id}, board, id, body} end)

    cards =
      from(c in Card,
        where: c.board_id in ^ids and like(c.description, "%[[%"),
        select: {c.id, c.board_id, c.description}
      )
      |> Repo.all()
      |> Enum.map(fn {id, board, body} -> {{:card, id}, board, nil, body} end)

    comments =
      from(m in Comment,
        left_join: c in Card,
        on: c.id == m.card_id,
        left_join: p in Page,
        on: p.id == m.page_id,
        where: (c.board_id in ^ids or p.board_id in ^ids) and like(m.body, "%[[%"),
        select: {m.id, coalesce(p.board_id, c.board_id), m.page_id, m.body}
      )
      |> Repo.all()
      |> Enum.map(fn {id, board, page, body} -> {{:comment, id}, board, page, body} end)

    pages ++ cards ++ comments
  end

  defp refs(body) do
    body |> Links.extract() |> Enum.filter(&(&1.kind == :page and &1.target != ""))
  end

  defp simplify(%{to: {:page, %Page{id: id}}}), do: {:page, id}
  defp simplify(%{to: {:file, file}}), do: {:file, file.id}
  defp simplify(%{to: nil}), do: nil
  defp simplify(%{to: other}), do: {elem(other, 0), :other}

  defp resolve(boards, board_id, from_id, refs) do
    from = from_id && Repo.get(Page, from_id)
    boards[board_id] |> Links.resolve(refs, from: from) |> Enum.map(&simplify/1)
  end

  defp boards_of(sources) do
    ids = sources |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    Repo.all(from(b in Board, where: b.id in ^ids)) |> Map.new(&{&1.id, &1})
  end

  defp resolve_all(sources, _vault) do
    boards = boards_of(sources)

    Index.cached(fn ->
      Map.new(sources, fn {key, board_id, from_id, body} ->
        found = refs(body)
        {key, Enum.zip(Enum.map(found, & &1.raw), resolve(boards, board_id, from_id, found))}
      end)
    end)
  end

  defp rewrite_links(sources, before, vault) do
    boards = boards_of(sources)

    found =
      Index.cached(fn ->
        by_page = vault |> Index.for_vault() |> Map.new(&{&1.id, &1})

        for {key, board_id, from_id, body} <- sources,
            {raw, was} <- before |> Map.get(key, []) |> Enum.uniq(),
            [ref] <- [refs(raw)],
            now <- resolve(boards, board_id, from_id, [ref]),
            was != nil,
            was != now do
          written = if ref.board, do: ref.board <> "/" <> ref.target, else: ref.target

          %{
            source: key,
            body: body,
            raw: raw,
            rewrite: proposal(raw, written, was, by_page, boards, board_id, from_id)
          }
        end
      end)

    {rewritten, unverified} = Enum.split_with(found, & &1.rewrite)

    rewritten
    |> Enum.group_by(& &1.source)
    |> Enum.each(fn {key, group} ->
      save_body(key, Enum.reduce(group, hd(group).body, &String.replace(&2, &1.raw, &1.rewrite)))
    end)

    {Enum.map(rewritten, &Map.delete(&1, :body)), Enum.map(unverified, &Map.delete(&1, :body))}
  end

  # The target's path below its board's folder, longest first, then the path
  # with it: the first that resolves back to the target.
  defp proposal(raw, written, {:page, id}, by_page, boards, board_id, from_id) do
    with %{segments: segments} <- by_page[id] do
      drops = Enum.to_list(1..(length(segments) - 1)//1) ++ [0]

      Enum.find_value(drops, fn drop ->
        candidate = segments |> Enum.drop(drop) |> Enum.join("/")
        new_raw = String.replace(raw, written, candidate, global: false)

        case refs(new_raw) do
          [ref] -> if resolve(boards, board_id, from_id, [ref]) == [{:page, id}], do: new_raw
          _ -> nil
        end
      end)
    end
  end

  defp proposal(_raw, _written, _was, _by_page, _boards, _board_id, _from_id), do: nil

  defp save_body({:page, id}, body) do
    {:ok, _} =
      Wiki.update_page(Repo.get!(Page, id), %{"body" => body},
        via: "migration",
        message: "migration: link rewrite",
        new_revision: true
      )
  end

  defp save_body({:card, id}, body),
    do: Repo.update_all(from(c in Card, where: c.id == ^id), set: [description: body])

  defp save_body({:comment, id}, body),
    do: Repo.update_all(from(c in Comment, where: c.id == ^id), set: [body: body])
end

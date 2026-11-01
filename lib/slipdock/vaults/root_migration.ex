defmodule Slipdock.Vaults.RootMigration do
  @moduledoc """
  Moves a person's vaults and pages to the one root vault (W-2201, #1596).

  Run deliberately (`mix slipdock.root_vault`, or `run_all/1` from a release),
  never on boot. One transaction per person, and running it twice changes
  nothing. `dry_run: true` does all of it, reports, and rolls back.

  For each person:

    1. **Before anything moves**, every `[[link]]` in their page bodies, card
       descriptions and comments is resolved against the old mappings.
    2. **Their vaults become one.** The survivor is the one quick notes go to,
       else the one with most mappings, else the oldest, so a mirror's id
       stays good. Mirrors, recordings, hotkeys, header links and settings
       come across, the rest are deleted, and the old mappings with them.
    3. **Renames:** `opts[:rename]`, `%{board code => new name}`.
    4. **Card pages:** a page pinned to a card on its own board moves to that
       card's folder, the first pin winning. A child page stays under its
       parent, and a cross-board pin stays a link. `opts[:keep_folders]`
       names top-level folders whose pages stay put.
    5. **Pass logs** take their new titles.
    6. **Links:** each one whose target has changed is rewritten to its full
       path, and only saved if that resolves to the old target. One that can't
       be verified is left alone and reported.
    7. **Inline tags** are read on every board, which are all in a vault now.

  Then, once for everyone, short names are filled in. `model: false` skips
  the model; a dry run always does, so it spends nothing.

  The `vault_mappings` table is emptied, not dropped: a rollback runs the old
  code on this schema, so dropping it is a later forward migration.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Comment, ShortNames}
  alias Slipdock.Repo
  alias Slipdock.Vaults
  alias Slipdock.Vaults.{Index, Layout, Vault}
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{CardFolders, Changes, Folder, GeneratedTitles, Link, Links, NoteTags, Page}

  @doc """
  Runs it for everyone with a board or a vault: `%{users: [report], short_names:
  %{named:, by_model:}, dry_run:}`. `opts` as the moduledoc says, plus `:user_ids`.
  """
  def run_all(opts \\ []) do
    dry_run = opts[:dry_run] == true
    reports = opts |> users() |> Enum.map(&run(&1, opts))

    short_names =
      if dry_run do
        %{named: count_unnamed(), by_model: 0}
      else
        ShortNames.backfill(model: opts[:model] != false)
      end

    %{users: reports, short_names: short_names, dry_run: dry_run}
  end

  defp users(opts) do
    owners = from(b in Board, where: is_nil(b.parent_card_id), select: b.owner_id)
    holders = from(v in Vault, select: v.user_id)

    query =
      from(u in User,
        where: u.id in subquery(owners) or u.id in subquery(holders),
        order_by: [asc: u.id]
      )

    query = if ids = opts[:user_ids], do: where(query, [u], u.id in ^ids), else: query
    Repo.all(query)
  end

  defp count_unnamed do
    Repo.aggregate(
      from(c in Card,
        where: is_nil(c.short_name) and not c.short_name_edited,
        where: fragment("char_length(trim(?)) > ?", c.title, ^ShortNames.long())
      ),
      :count
    )
  end

  @doc "One person, in one transaction: the report. See the moduledoc."
  def run(%User{} = user, opts \\ []) do
    result =
      Repo.transaction(
        fn ->
          report = migrate(user, opts)
          if opts[:dry_run] == true, do: Repo.rollback({:dry_run, report}), else: report
        end,
        timeout: :infinity
      )

    case result do
      {:ok, report} -> report
      {:error, {:dry_run, report}} -> report
    end
  end

  defp migrate(user, opts) do
    mappings = old_mappings(user)
    old_index = old_index(mappings)
    mapped_boards = mappings |> Enum.map(& &1.board_id) |> MapSet.new()
    old_folder = quick_note_target(user, mappings)

    {vault, vault_report} = one_vault(user, mappings)
    renamed = rename_boards(user, opts[:rename] || %{})
    old_paths = paths(vault)

    sources = sources(vault)
    before = resolve_before(sources, vault, old_index, mapped_boards)

    moved = move_card_pages(vault, opts[:keep_folders] || [])
    titles = retitle_pass_logs(vault)
    rewrites = rewrite_links(sources, before, vault)

    Enum.each(Vaults.board_ids(vault), &NoteTags.refresh_board/1)
    quick_note_folder(user, vault, old_folder)
    announce(vault)

    %{
      user_id: user.id,
      email: user.email,
      vault: vault_report,
      renamed: renamed,
      moved: moved,
      titles: titles,
      rewrites: rewrites,
      old_paths: old_paths,
      new_paths: paths(vault),
      check: check(vault, sources, before)
    }
  end

  ## The old world ---------------------------------------------------------------

  defp old_mappings(%User{id: user_id}) do
    from(m in "vault_mappings",
      join: v in Vault,
      on: v.id == m.vault_id,
      where: v.user_id == ^user_id,
      order_by: [asc: m.id],
      select: %{
        vault_id: m.vault_id,
        board_id: m.board_id,
        folder_id: m.folder_id,
        path: m.path
      }
    )
    |> Repo.all()
  end

  # Where each page was, in the shape `Index` builds, from the mappings: the
  # deepest mapping above a page holds it.
  defp old_index([]), do: []

  defp old_index(mappings) do
    board_ids = mappings |> Enum.map(& &1.board_id) |> Enum.uniq()

    folders =
      from(f in Folder, where: f.board_id in ^board_ids, select: {f.id, {f.parent_id, f.name}})
      |> Repo.all()
      |> Map.new()

    pages =
      from(p in Page,
        where: p.board_id in ^board_ids,
        select: %{
          id: p.id,
          board_id: p.board_id,
          parent_id: p.parent_id,
          folder_id: p.folder_id,
          title: p.title,
          slug: p.slug,
          aliases: p.aliases,
          file_name: p.file_name,
          archived: not is_nil(p.archived_at)
        }
      )
      |> Repo.all()

    by_id = Map.new(pages, &{&1.id, &1})
    by_board = Enum.group_by(mappings, & &1.board_id)

    pages
    |> Enum.reject(& &1.archived)
    |> Enum.flat_map(fn page ->
      case old_segments(page, by_id, folders, Map.get(by_board, page.board_id, [])) do
        nil -> []
        segments -> [Index.entry(page, segments)]
      end
    end)
    |> Enum.sort_by(&{length(&1.segments), &1.path})
  end

  defp old_segments(page, by_id, folders, mappings) do
    {top, above} = ancestry(page, by_id, [])
    chain = folder_chain(top.folder_id, folders, [])

    mappings
    |> Enum.map(fn m -> {old_depth(m.folder_id, chain), m} end)
    |> Enum.reject(fn {depth, _m} -> is_nil(depth) end)
    |> Enum.max_by(fn {depth, _m} -> depth end, fn -> nil end)
    |> case do
      nil ->
        nil

      {depth, m} ->
        below = chain |> Enum.drop(depth + 1) |> Enum.map(&elem(folders[&1], 1))

        String.split(m.path, "/", trim: true) ++
          below ++ Enum.map(above, & &1.title) ++ [page.title]
    end
  end

  defp old_depth(nil, _chain), do: -1
  defp old_depth(id, chain), do: Enum.find_index(chain, &(&1 == id))

  defp ancestry(%{parent_id: nil} = page, _by_id, acc), do: {page, acc}

  defp ancestry(page, by_id, acc) do
    case by_id[page.parent_id] do
      nil -> {page, acc}
      parent when length(acc) > 64 -> {parent, acc}
      parent -> ancestry(parent, by_id, [parent | acc])
    end
  end

  defp folder_chain(nil, _folders, acc), do: acc

  defp folder_chain(id, folders, acc) do
    case folders[id] do
      {parent_id, _name} when length(acc) < 64 -> folder_chain(parent_id, folders, [id | acc])
      _ -> acc
    end
  end

  # The folder or board quick notes went to, so it can be found again.
  defp quick_note_target(%User{quick_note_folder: path, quick_note_vault_id: id}, mappings)
       when is_binary(path) and is_integer(id) do
    segments = String.split(path, "/", trim: true)
    want = Enum.map(segments, &String.downcase/1)

    mappings
    |> Enum.filter(&(&1.vault_id == id))
    |> Enum.map(fn m -> {String.split(m.path, "/", trim: true), m} end)
    |> Enum.filter(fn {prefix, _m} ->
      Enum.map(prefix, &String.downcase/1) == Enum.take(want, length(prefix))
    end)
    |> Enum.max_by(fn {prefix, _m} -> length(prefix) end, fn -> nil end)
    |> case do
      nil -> nil
      {prefix, m} -> {m.board_id, m.folder_id, Enum.drop(segments, length(prefix))}
    end
  end

  defp quick_note_target(_user, _mappings), do: nil

  ## One vault -------------------------------------------------------------------

  defp one_vault(%User{id: user_id} = user, mappings) do
    vaults = Repo.all(from(v in Vault, where: v.user_id == ^user_id, order_by: [asc: v.id]))
    counts = Enum.frequencies_by(mappings, & &1.vault_id)

    case vaults do
      [] ->
        vault = Vaults.root(user)
        {vault, %{kept: vault.id, merged: []}}

      _ ->
        keep = survivor(vaults, counts, user)
        others = Enum.reject(vaults, &(&1.id == keep.id))
        keep = Enum.reduce(others, keep, &absorb/2)
        Enum.each(others, &Repo.delete!/1)
        Repo.delete_all(from(m in "vault_mappings", where: m.vault_id == ^keep.id))

        if user.quick_note_vault_id do
          from(u in User, where: u.id == ^user_id)
          |> Repo.update_all(set: [quick_note_vault_id: keep.id])
        end

        {keep, %{kept: keep.id, name: keep.name, merged: Enum.map(others, & &1.id)}}
    end
  end

  defp survivor(vaults, counts, user) do
    Enum.find(vaults, &(&1.id == user.quick_note_vault_id)) ||
      Enum.max_by(vaults, &{Map.get(counts, &1.id, 0), -&1.id})
  end

  # What hangs off a vault that is going, onto the one that stays. A clash on
  # a unique index means the survivor has its own, which is kept.
  defp absorb(%Vault{id: from} = other, %Vault{id: to} = keep) do
    for {table, key} <- [
          {"vault_mirrors", "token_id"},
          {"recording_files", "path"},
          {"board_hotkeys", "user_id"},
          {"header_links", "user_id"}
        ] do
      Repo.query!(
        "DELETE FROM #{table} a USING #{table} b " <>
          "WHERE a.vault_id = $1 AND b.vault_id = $2 AND a.#{key} = b.#{key}",
        [from, to]
      )

      Repo.query!("UPDATE #{table} SET vault_id = $1 WHERE vault_id = $2", [to, from])
    end

    changes =
      [
        recordings_folder: keep.recordings_folder || other.recordings_folder,
        shortcut: keep.shortcut || other.shortcut,
        position: keep.position || other.position
      ]
      |> Keyword.reject(fn {key, value} -> value == Map.get(keep, key) end)

    # The other's key goes with it first: it is unique.
    if changes[:shortcut], do: other |> Ecto.Changeset.change(shortcut: nil) |> Repo.update!()
    keep |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  defp rename_boards(%User{id: user_id}, renames) do
    for {code, name} <- renames,
        %Board{} = board <- [
          Repo.one(from(b in Board, where: b.code == ^code and b.owner_id == ^user_id))
        ],
        board.name != name do
      board |> Ecto.Changeset.change(name: name) |> Repo.update!()
      %{code: code, from: board.name, to: name}
    end
  end

  defp quick_note_folder(_user, _vault, nil), do: :ok

  defp quick_note_folder(%User{id: user_id}, vault, {board_id, folder_id, rest}) do
    dirs = Layout.dirs(vault)
    base = if folder_id, do: dirs.folders[folder_id], else: dirs.boards[board_id]

    if base do
      path = Enum.join([base | rest], "/")
      from(u in User, where: u.id == ^user_id) |> Repo.update_all(set: [quick_note_folder: path])
    end

    :ok
  end

  defp announce(vault) do
    # One row a board wakes every follower, who re-lists.
    for {board_id, _dir} <- Layout.dirs(vault).boards,
        do: Changes.record(board_id, "board", board_id)

    :ok
  end

  defp paths(vault) do
    layout = Layout.build(vault)

    %{
      pages: Map.new(layout.pages, fn {id, p} -> {id, p.path} end),
      files: Map.new(layout.files, fn {id, f} -> {id, f.path} end)
    }
  end

  ## Links -----------------------------------------------------------------------

  # Every place a [[link]] can be written: `{key, board_id, from_page_id, body}`.
  defp sources(vault) do
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
        select: {m.id, coalesce(c.board_id, p.board_id), m.page_id, m.body}
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

  # A board in no old mapping looked across no vault, so it sees an empty one.
  defp resolve_before(sources, vault, old_index, mapped) do
    boards = boards_of(sources)

    {inside, outside} = Enum.split_with(sources, &MapSet.member?(mapped, elem(&1, 1)))

    resolve_all(inside, boards, vault, old_index)
    |> Map.merge(resolve_all(outside, boards, vault, []))
  end

  defp resolve_all(sources, boards, vault, index) do
    Index.with_index(vault, index, fn ->
      Map.new(sources, fn {key, board_id, from_id, body} ->
        found = refs(body)
        {key, Enum.zip(Enum.map(found, & &1.raw), resolve(boards, board_id, from_id, found))}
      end)
    end)
  end

  defp rewrite_links(sources, before, vault) do
    boards = boards_of(sources)

    Index.cached(fn ->
      index = Index.for_vault(vault)
      by_page = Map.new(index, &{&1.id, &1})

      for {key, board_id, from_id, body} <- sources,
          {raw, was} <- before |> Map.get(key, []) |> Enum.uniq(),
          [ref] <- [refs(raw)],
          # A generator, not `now = ...`: in a `for` that would be a filter,
          # and drop every link that now finds nothing.
          now <- resolve(boards, board_id, from_id, [ref]),
          was != nil,
          was != now do
        written = if ref.board, do: ref.board <> "/" <> ref.target, else: ref.target
        proposal = proposal(raw, written, was, by_page, boards, board_id, from_id)
        %{source: key, body: body, raw: raw, was: was, now: now, rewrite: proposal}
      end
    end)
    |> save_rewrites()
  end

  # The fullest form of the target's path that resolves back to it.
  defp proposal(raw, written, {:page, id}, by_page, boards, board_id, from_id) do
    with %{segments: segments} <- by_page[id] do
      Enum.find_value(0..(length(segments) - 1), fn drop ->
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

  defp save_rewrites(rewrites) do
    rewrites
    |> Enum.filter(& &1.rewrite)
    |> Enum.group_by(& &1.source)
    |> Enum.each(fn {key, group} ->
      body =
        Enum.reduce(group, hd(group).body, &String.replace(&2, &1.raw, &1.rewrite))

      save_body(key, body)
    end)

    Enum.map(rewrites, &Map.delete(&1, :body))
  end

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

  ## Pages -----------------------------------------------------------------------

  defp move_card_pages(vault, keep_folders) do
    ids = Vaults.board_ids(vault)
    tops = top_folders(ids)
    keep = MapSet.new(keep_folders, &String.downcase/1)

    pins =
      from(l in Link,
        join: p in Page,
        on: p.id == l.page_id,
        join: c in Card,
        on: c.id == l.target_card_id,
        where: l.pinned and p.board_id in ^ids and is_nil(p.archived_at),
        order_by: [asc: l.id],
        select: %{
          page: p,
          card: c,
          folder_id: p.folder_id,
          parent_id: p.parent_id,
          same_board: p.board_id == c.board_id
        }
      )
      |> Repo.all()

    firsts = Enum.uniq_by(pins, & &1.page.id)

    {own, cross} = Enum.split_with(firsts, & &1.same_board)
    {children, own} = Enum.split_with(own, &(&1.parent_id != nil))
    {kept, own} = Enum.split_with(own, &kept?(&1, tops, keep))

    moved =
      Enum.flat_map(own, fn %{page: page, card: card} ->
        {:ok, folder} = CardFolders.ensure(card)

        if page.folder_id == folder.id do
          []
        else
          from(p in Page, where: p.id == ^page.id) |> Repo.update_all(set: [folder_id: folder.id])

          [
            %{
              page_id: page.id,
              code: page.code,
              title: page.title,
              card_id: card.id,
              from: tops[page.folder_id]
            }
          ]
        end
      end)

    %{
      moved: moved,
      kept:
        Enum.map(
          kept,
          &%{
            page_id: &1.page.id,
            code: &1.page.code,
            title: &1.page.title,
            folder: tops[&1.folder_id]
          }
        ),
      cross_board: length(cross),
      second_pins: length(pins) - length(firsts),
      children: length(children)
    }
  end

  defp kept?(%{folder_id: id}, tops, keep) do
    id != nil and tops[id] != nil and
      MapSet.member?(keep, tops[id] |> String.split("/") |> hd() |> String.downcase())
  end

  # Each folder's path of names from its board's top.
  defp top_folders(board_ids) do
    rows =
      Repo.all(
        from(f in Folder, where: f.board_id in ^board_ids, select: {f.id, {f.parent_id, f.name}})
      )

    folders = Map.new(rows)

    Map.new(rows, fn {id, _} ->
      {id, id |> folder_chain(folders, []) |> Enum.map_join("/", &elem(folders[&1], 1))}
    end)
  end

  defp retitle_pass_logs(vault) do
    ids = Vaults.board_ids(vault)

    from(p in Page,
      where: p.board_id in ^ids and is_nil(p.archived_at),
      where: like(p.title, "Pass log%"),
      select: struct(p, [:id, :title])
    )
    |> Repo.all()
    |> Enum.flat_map(fn page ->
      case GeneratedTitles.pass_log(page.title) do
        nil ->
          []

        title ->
          from(p in Page, where: p.id == ^page.id) |> Repo.update_all(set: [title: title])
          [%{page_id: page.id, from: page.title, to: title}]
      end
    end)
  end

  ## Checks ----------------------------------------------------------------------

  # After it all: every live page has a path, and every link still resolves as
  # it did, or is one the report names as unverified. Read fresh, so a rewrite
  # is judged on what was saved.
  defp check(vault, sources, before) do
    ids = Vaults.board_ids(vault)
    placed = vault |> Layout.build() |> Map.fetch!(:pages) |> map_size()

    live =
      Repo.aggregate(from(p in Page, where: p.board_id in ^ids and is_nil(p.archived_at)), :count)

    bodies = current_bodies(sources)
    boards = boards_of(sources)

    changed =
      Index.cached(fn ->
        for {key, board_id, from_id, _} <- sources,
            was = before |> Map.get(key, []) |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1),
            was != [],
            found = refs(bodies[key]),
            now = resolve(boards, board_id, from_id, found),
            target <- was -- now do
          %{source: key, target: target}
        end
      end)

    %{pages_placed: placed, pages_live: live, links_lost: changed}
  end

  defp current_bodies(sources) do
    Map.new(sources, fn {key, _board, _from, _body} = source -> {key, current(source)} end)
  end

  defp current({{:page, id}, _b, _f, _body}),
    do: Repo.one(from(p in Page, where: p.id == ^id, select: p.body))

  defp current({{:card, id}, _b, _f, _body}),
    do: Repo.one(from(c in Card, where: c.id == ^id, select: c.description))

  defp current({{:comment, id}, _b, _f, _body}),
    do: Repo.one(from(c in Comment, where: c.id == ^id, select: c.body))
end

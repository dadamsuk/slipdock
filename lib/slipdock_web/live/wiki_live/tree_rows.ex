defmodule SlipdockWeb.WikiLive.TreeRows do
  @moduledoc """
  The wiki tree's rows (`WikiLive.Index`): what the `WikiTree` hook is
  sent when it asks for a container, a page of a big folder or a hover's
  preview, shaped as the client draws them, and the vault view's address.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.WikiLive.Format
  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Vaults.Names
  alias Slipdock.Wiki.{CardFolders, Folder, Icons, Page, Tree, TreeStates}
  alias SlipdockWeb.Params
  alias SlipdockWeb.Wiki.Renderer
  alias SlipdockWeb.WikiLive.{State, TreeOps}

  # How much the tree asks for at once: a page of a big folder's rows, and
  # at most this many open containers in one go.
  @tree_page 500

  # A wiki this small opens with every folder open on a first visit, as the
  # tree always did; a bigger one opens only the way to what is shown.
  @tree_small 300

  # A page the tree's keyboard acts on: on a board the reader can write to.
  def tree_page(socket, id), do: TreeOps.tree_item(socket, "page:#{id}")

  # A filter in the vault's tree filters every board of it (R11.5), worked out
  # when asked for; this board's is worked out with the filter bar. On a
  # board in a vault, and in another board's tree, it filters what that tree
  # shows: the vault from the board's folder down (#758).
  def scope_filter(%{assigns: %{tree_filter: nil}}, _scope), do: nil

  def scope_filter(socket, "vault") do
    Tree.vault_filter(
      socket.assigns.vault,
      State.vault_boards(socket),
      socket.assigns.filters,
      [contents: socket.assigns.tree_contents] ++
        if(socket.assigns.tree_context, do: [root: socket.assigns.tree_context_root], else: [])
    )
  end

  def scope_filter(socket, _board) do
    case board_vault_root(socket) do
      nil ->
        socket.assigns.tree_filter

      root ->
        result =
          Tree.vault_filter(
            socket.assigns.vault,
            State.vault_boards(socket),
            socket.assigns.filters,
            contents: socket.assigns.tree_contents,
            root: root
          )

        # Its top is this tree's root, and this board's own top rows are in
        # it already.
        {top, nodes} = Map.pop(result.nodes, result.top)
        nodes = Map.delete(nodes, "board:#{socket.assigns.board.id}")
        nodes = if top, do: Map.put(nodes, "root", top), else: nodes
        %{result | nodes: nodes}
    end
  end

  # This board's folder in its vault: its tree is the vault's from there
  # down. Nil off a vault.
  def board_vault_root(%{assigns: %{vault: nil}}), do: nil

  def board_vault_root(socket),
    do: Tree.vault_root(socket.assigns.vault, socket.assigns.board.id, State.vault_boards(socket))

  # The page the rows of its container must reach, however far down a big
  # folder it is: the one asked for (`through`, when the hook reveals the
  # page being read), or else the page being read, in its own container.
  def through(_socket, %{"through" => "page:" <> id, "keys" => [key | _]}, _root) do
    case Params.id(id) do
      nil -> nil
      id -> {key, id}
    end
  end

  def through(%{assigns: %{page: %Page{id: id}, tree_reveal: reveal}}, _params, root),
    do: {List.last(reveal) || root, id}

  def through(_socket, _params, _root), do: nil

  def nodes_map(nodes) when is_map(nodes), do: nodes
  def nodes_map(nodes), do: Map.new(nodes)

  # Which kept open set this tree is: the board's own (also when it is shown
  # from one of its pages on another board), or its vault's.
  def tree_state_scope(%{assigns: %{tree_context: %{id: id}}}),
    do: TreeStates.scope(:board, id)

  def tree_state_scope(%{assigns: %{tree_scope: "vault", vault: %{id: id}}}),
    do: TreeStates.scope(:vault, id)

  def tree_state_scope(%{assigns: %{board: board}}), do: TreeStates.scope(:board, board.id)

  def keys_param(keys) when is_list(keys), do: Enum.filter(keys, &is_binary/1)
  def keys_param(_), do: []

  # Each asked-for container's rows, the board's folders and counts read
  # once for all of them. A key that is gone, or not this reader's, is left
  # out, and the hook stops asking for it.
  def load_nodes(socket, "vault", keys, through) do
    boards = State.vault_boards(socket)
    layout = Tree.vault_prepare(socket.assigns.vault, boards)

    for key <- keys,
        extra = [layout: layout, limit: @tree_page] ++ through_opt(through, key),
        {:ok, rows} <- [Tree.vault_children(socket.assigns.vault, key, boards, extra)],
        do: {key, rows}
  end

  # A board in a vault: its own rows, read with its folders and counts once,
  # and what is below them, its top being its place in the vault.
  def load_nodes(%{assigns: %{vault: %{} = vault, board: board}} = socket, _board, keys, through) do
    boards =
      Map.update!(State.vault_boards(socket), board.id, fn {board, opts} ->
        {board, Tree.prepare(board, opts)}
      end)

    layout = Tree.vault_prepare(vault, boards)

    for key <- keys,
        extra = [layout: layout, limit: @tree_page] ++ through_opt(through, key),
        {:ok, rows} <- [Tree.vault_children(vault, board_key(socket, key), boards, extra)],
        do: {key, rows}
  end

  def load_nodes(socket, _board, keys, through) do
    opts = Tree.prepare(socket.assigns.board, State.tree_opts(socket.assigns))

    for key <- keys,
        {:ok, ref} <- [Tree.parse_ref(key)],
        extra = [limit: @tree_page] ++ through_opt(through, key),
        {:ok, rows} <- [Tree.children(socket.assigns.board, ref, extra ++ opts)],
        do: {key, rows}
  end

  # The board a previewed page is on, with the options its tree rows are
  # read with: this board, or another of the vault's the reader can read.
  def preview_board(%{assigns: %{board: %{id: id} = board}} = socket, id),
    do: {board, State.tree_opts(socket.assigns)}

  def preview_board(socket, board_id), do: Map.get(State.vault_boards(socket), board_id)

  def preview_reply(%{page: page} = found, board, here) do
    %{
      found: true,
      key: "page:#{page.id}",
      title: page.title,
      code: page.code,
      board: if(board.id != here.id, do: board.name),
      summary: if(not Enum.member?([nil, ""], page.summary), do: page.summary),
      paragraphs: Renderer.preview_paragraphs(found.body || ""),
      tags: page.note_tags || [],
      children: found.children,
      draft: page.status == "draft",
      template: page.template == true,
      archived: page.archived_at != nil,
      updated:
        page.updated_at &&
          SlipdockWeb.SlipdockComponents.relative_time(as_datetime(page.updated_at)),
      updated_by: found.updated_by && Slipdock.Accounts.User.display_name(found.updated_by)
    }
  end

  defp through_opt({key, id}, key), do: [through: id]
  defp through_opt(_through, _key), do: []

  # A container seen through a placed folder (#808): read on the board it
  # is on, if the reader may, and keyed for where it is seen.
  def via_nodes(socket, keys) do
    for key <- keys,
        {:ok, rows} <- [via_rows(socket, key, limit: @tree_page)],
        do: {key, rows}
  end

  defp via_rows(socket, key, extra) do
    with {:ok, chain, inner} <- Tree.split_via(key),
         {:ok, ref} <- Tree.parse_ref(inner),
         board_id when is_integer(board_id) <- via_board_id(ref),
         {board, opts} <- preview_board(socket, board_id) || shared_board(socket, ref),
         {:ok, rows} <- Tree.children(board, ref, extra ++ opts) do
      {:ok, Tree.through_placement(rows, chain)}
    else
      _ -> :error
    end
  end

  # A folder shared with the reader and filed in one of theirs (#818) opens
  # there to what the share reaches: its board is read for it alone.
  defp shared_board(socket, {:folder, id}) do
    user = socket.assigns.current_user

    with %Folder{} = folder <- Wiki.get_folder(id),
         level when level != :none <- Access.share_permission(user, folder) do
      opts = State.list_opts(Access.can_write?(level), socket.assigns.show) ++ [as: user]
      {Boards.get_board!(folder.board_id), opts}
    else
      _ -> nil
    end
  end

  defp shared_board(_socket, _ref), do: nil

  defp via_board_id({:folder, id}), do: with(%Folder{board_id: b} <- Wiki.get_folder(id), do: b)
  defp via_board_id({:page, id}), do: with(%Page{board_id: b} <- Wiki.get_page(id), do: b)

  def container_rows(socket, scope, "at:" <> _ = key, extra) when is_binary(scope),
    do: via_rows(socket, key, extra)

  def container_rows(socket, "vault", key, extra),
    do: Tree.vault_children(socket.assigns.vault, key, State.vault_boards(socket), extra)

  def container_rows(
        %{assigns: %{vault: %{} = vault, tree_filter: nil}} = socket,
        _board,
        key,
        extra
      ),
      do: Tree.vault_children(vault, board_key(socket, key), State.vault_boards(socket), extra)

  def container_rows(socket, _board, key, extra), do: State.tree_rows(socket, key, extra)

  # This board's top, as the vault's tree keys it.
  defp board_key(socket, "root"), do: "board:#{socket.assigns.board.id}"
  defp board_key(_socket, key), do: key

  # Every container "open all" opens: the folders, and in a vault the
  # boards and every folder on them too.
  def all_container_keys(socket, "vault") do
    boards = State.vault_boards(socket)
    Tree.vault_folder_keys(socket.assigns.vault, boards)
  end

  def all_container_keys(%{assigns: %{vault: %{} = vault}} = socket, _board) do
    case board_vault_root(socket) do
      nil -> Enum.map(socket.assigns.all_folders, &"folder:#{&1.id}")
      root -> Tree.vault_folder_keys(vault, State.vault_boards(socket), root: root)
    end
  end

  def all_container_keys(socket, _board),
    do: Enum.map(socket.assigns.all_folders, &"folder:#{&1.id}")

  # A row as the hook draws it: its key, where it links to, and whether
  # following that link stays in this view (a patch) or opens another
  # board's wiki. Only what is drawn goes over the wire.
  def client_rows(rows, socket), do: client_rows(rows, socket, row_access(socket))

  # `access` is `row_access/1`'s, worked out once for every container a
  # reply carries: in a vault it reads each of its boards, and a reply can
  # carry hundreds of containers.
  def client_rows(rows, socket, {writable, readable}) do
    dressed? = socket.assigns.board.wiki_tree_icons != false
    shared = shared_keys(rows)

    rows
    |> name_rows(socket)
    |> Enum.map(&(&1 |> client_row(writable) |> dress_row(&1, dressed?)))
    |> Enum.map(&mark_shared(&1, shared))
    |> Enum.map(&through_share(&1, readable, writable, socket.assigns.board.id))
    |> in_vault_view(socket.assigns)
    |> in_context(socket.assigns)
  end

  # Rows as this reader wants things called (`users.tree_names`): a card's
  # folder by its full title or its short name, `:full` keeping the title for
  # the row's hover. Pages have no short name.
  def name_rows(rows, socket) do
    choice = tree_names(socket)
    labels = CardFolders.labels(for %{kind: "folder", id: id} when is_integer(id) <- rows, do: id)

    Enum.map(rows, fn row ->
      case labels[row[:id]] ||
             (row[:short_name] && %{title: row.title, short_name: row.short_name}) do
        nil -> row
        label -> Map.merge(row, %{title: Names.pick(label, choice), full: label.title})
      end
    end)
  end

  def tree_names(%{assigns: assigns}) do
    case assigns[:current_user] do
      %{tree_names: choice} -> choice
      _ -> "full"
    end
  end

  # A row of another board in this tree opens with `?in=` the board whose
  # tree it is, which keeps it (#758): this board's, or the one this was
  # opened from.
  def in_context(rows, %{vault_view: nil, vault: %{}} = assigns) do
    context = (assigns.tree_context || assigns.board).id

    Enum.map(rows, fn
      %{href: "/boards/" <> _ = href, board_id: id} = row when id not in [nil, context] ->
        if row.kind == "file",
          do: row,
          else: %{row | href: href <> if(href =~ "?", do: "&", else: "?") <> "in=#{context}"}

      row ->
        row
    end)
  end

  def in_context(rows, _assigns), do: rows

  # In the vault view a row opens at its vault address, patched in even when
  # the page is on another board (see `State.switch_board/3`).
  # A board's own row too (W-2201): it opens the board's folder here, in the
  # one tree, not the board's wiki on its own.
  def in_vault_view(rows, %{vault_view: %{} = vault, vault_addresses: addresses}) do
    Enum.map(rows, fn row ->
      path =
        case row do
          %{kind: "page", id: id} -> addresses.pages[id]
          %{kind: "folder", id: id} when is_integer(id) -> addresses.folders[id]
          %{kind: "folder", key: "board:" <> id} -> board_address(addresses, id)
          _ -> nil
        end

      if path,
        do: %{row | href: SlipdockWeb.VaultUrls.url(vault, path), nav: "patch"},
        else: row
    end)
  end

  def in_vault_view(rows, _assigns), do: rows

  defp board_address(addresses, id) do
    case Integer.parse(id) do
      {n, ""} -> addresses.boards[n]
      _ -> nil
    end
  end

  # `{writable, readable}`: the boards whose rows the reader can move, rename
  # and archive (this one when they can write to it, and the vault's others
  # they can write to), and the boards whose rows open in their own wiki.
  # In a vault both come from one read of its boards: a full board load each,
  # as `TreeOps.writable_board/2` does, is far too slow for a vault of a hundred.
  def row_access(%{assigns: %{vault: %{}}} = socket) do
    %{board: here, can_write: can_write, current_user: user} = socket.assigns
    boards = State.vault_boards(socket)

    writable =
      for {id, {board, _opts}} <- boards,
          id != here.id,
          Access.can_write?(Access.board_permission(user, board)),
          into: MapSet.new(),
          do: id

    writable = if can_write, do: MapSet.put(writable, here.id), else: writable
    readable = boards |> Map.keys() |> MapSet.new() |> MapSet.put(here.id)
    {writable, readable}
  end

  def row_access(socket) do
    here = socket.assigns.board.id
    writable = if socket.assigns.can_write, do: MapSet.new([here]), else: MapSet.new()
    {writable, MapSet.new([here])}
  end

  # Whether the tree is small enough to open whole on a first visit. The
  # vault view's tree is the whole vault, not the board it stands on.
  def tree_small?(%{assigns: %{vault_view: %{}, tree_scope: "vault"} = assigns}),
    do: map_size(assigns.vault_addresses.pages) <= @tree_small

  def tree_small?(socket), do: socket.assigns.shown + socket.assigns.hidden <= @tree_small

  defp client_row(%{kind: "more"} = row, _writable),
    do: %{kind: "more", key: "more:#{row.offset}", offset: row.offset, count: 0}

  defp client_row(row, writable) do
    key = row[:key] || "#{row.kind}:#{row.id}"

    base =
      row
      |> Map.take([:kind, :id, :board_id, :title, :full, :count, :pages, :code, :placed_in])
      |> Map.merge(%{
        key: key,
        href: row_href(row, key),
        # Another board's row too: `State.switch_board/3` moves the view to it.
        nav: "patch"
      })

    base =
      Enum.reduce(
        [:draft, :template, :archived, :encrypted, :context, :also, :mount, :via],
        base,
        fn flag, acc ->
          if row[flag], do: Map.put(acc, flag, true), else: acc
        end
      )

    base
    |> then(
      &if(MapSet.member?(writable, row[:board_id]), do: Map.put(&1, :writable, true), else: &1)
    )
    |> then(&if(row[:sort], do: Map.put(&1, :sort, row.sort), else: &1))
  end

  # A row of somebody else's, shared with the reader and filed in a folder
  # of theirs (#818): it opens in the Shared view, since its board is not
  # theirs to open, and whoever writes the folder may take it out again.
  defp through_share(%{board_id: id} = row, readable, writable, board_id)
       when is_integer(id) and row.kind in ["page", "folder"] do
    if MapSet.member?(readable, id) do
      row
    else
      href =
        if row.kind == "page",
          do: ~p"/shared/pages/#{row.id}",
          else: ~p"/shared/folders/#{row.id}"

      row = %{row | href: href, nav: "redirect"}

      if row[:placed_in] && MapSet.member?(writable, board_id),
        do: Map.put(row, :writable, true),
        else: row
    end
  end

  defp through_share(row, _readable, _writable, _board_id), do: row

  # Which rows have been shared with somebody (#813), as "page:<id>" keys:
  # their owner and the board's members see a mark beside them. Writers on
  # the row's board may share it, so its menu offers Share… to them.
  defp shared_keys(rows) do
    pages = for %{kind: "page", id: id} when is_integer(id) <- rows, do: id
    folders = for %{kind: "folder", id: id} when is_integer(id) <- rows, do: id

    MapSet.union(
      pages |> Access.shared_page_ids() |> MapSet.new(&"page:#{&1}"),
      folders |> Access.shared_folder_ids() |> MapSet.new(&"folder:#{&1}")
    )
  end

  defp mark_shared(%{kind: kind, id: id} = row, shared) do
    row = if MapSet.member?(shared, "#{kind}:#{id}"), do: Map.put(row, :shared, true), else: row

    if row[:writable] && Enum.member?(["page", "folder"], kind) && !row[:also] && !row[:via],
      do: Map.put(row, :shareable, true),
      else: row
  end

  defp mark_shared(row, _shared), do: row

  # A folder's or page's own icon and colour (#792), as the classes the hook
  # draws, when the board shows them in the tree. Rows without either go as
  # they were, and the hook draws the plain icon of their kind.
  defp dress_row(%{kind: kind} = row, source, true) when kind in ["folder", "page", "dir"] do
    row
    |> put_present(:icon, Icons.class(source[:icon]))
    |> put_present(:tint, Icons.tint(source[:color]))
  end

  defp dress_row(row, _source, _dressed?), do: row

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  def row_href(%{kind: "page"} = row, _key), do: ~p"/boards/#{row.board_id}/wiki/#{row.slug}"

  def row_href(%{kind: "file"} = row, _key),
    do: Slipdock.Wiki.Files.open_path(%Slipdock.Wiki.WikiFile{id: row.id, name: row.title})

  def row_href(%{kind: "dir"}, _key), do: nil
  def row_href(%{board_id: board_id}, "board:" <> _), do: ~p"/boards/#{board_id}/wiki"

  def row_href(%{board_id: board_id}, "folder:" <> id),
    do: ~p"/boards/#{board_id}/wiki?#{[folder: id]}"

  def row_href(_row, _key), do: nil

  # What a vault view's address names, and the board whose wiki shows it.
  def vault_target(vault, params), do: vault_resolved(vault, vault_found(vault, params))

  # What the address names: a page or folder by id, else a vault path.
  defp vault_found(vault, params) do
    cond do
      id = Params.id(params["page"]) ->
        {:page, id}

      id = Params.id(params["folder"]) ->
        {:folder, id}

      true ->
        case Enum.join(params["path"] || [], "/") do
          "" -> top_of(vault)
          path -> Slipdock.Vaults.resolve_address(vault, path)
        end
    end
  end

  defp vault_resolved(vault, found) do
    case found do
      {:page, id} ->
        with %Page{} = page <- Wiki.get_page(id),
             true <- Enum.member?(Slipdock.Vaults.board_ids(vault), page.board_id),
             do: {:ok, {:page, id}, page.board_id},
             else: (_ -> :error)

      {:folder, id} ->
        with %Folder{} = folder <- Wiki.get_folder(id),
             true <- Enum.member?(Slipdock.Vaults.board_ids(vault), folder.board_id),
             do: {:ok, {:folder, id}, folder.board_id},
             else: (_ -> :error)

      {:top, board_id} ->
        {:ok, {:index, ""}, board_id}

      {:board, id} ->
        {:ok, {:index, Slipdock.Vaults.addresses(vault).boards[id]}, id}

      {:empty, vault} ->
        {:error, :empty, vault}

      _ ->
        :error
    end
  end

  # The top of a vault is no board's, but the view needs one to stand on:
  # the first root board, a live one if there is one.
  defp top_of(vault) do
    roots = for %{board: b} <- Slipdock.Vaults.boards(vault), is_nil(b.parent_card_id), do: b

    case Enum.find(roots, &is_nil(&1.archived_at)) || List.first(roots) do
      nil -> {:empty, vault}
      board -> {:top, board.id}
    end
  end

  # The vault view's address for what is shown now.
  def vault_here(%{assigns: %{vault_view: %{} = vault} = assigns}) do
    path =
      case assigns do
        %{page: %Page{id: id}} -> assigns.vault_addresses.pages[id]
        %{folder: %Folder{id: id}} -> assigns.vault_addresses.folders[id]
        _ -> nil
      end

    SlipdockWeb.VaultUrls.url(vault, path || "")
  end

  def vault_here(_socket), do: nil
end

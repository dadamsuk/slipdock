defmodule SlipdockWeb.BoardLive.State do
  @moduledoc """
  The board LiveView's state, as assigns: the board and what the reader may
  do on it, the lists as the filters show them, the view configuration the
  URL describes and what it builds, and finding the card or page an event
  names — on this board's tree, and only if the reader may touch it.

  Shared by `BoardLive.Show` and the modules it hands events to
  (`BoardLive.ViewEvents`, `BoardLive.Keyboard`). The panels are
  LiveComponents with state of their own, and check access for themselves.
  """
  use SlipdockWeb, :verified_routes

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_patch: 2, push_navigate: 2, put_flash: 3]
  import SlipdockWeb.BoardLive.Paths
  import SlipdockWeb.BoardLive.Items

  alias Slipdock.{
    Access,
    Boards,
    Narrative,
    Outline,
    Prioritise,
    Swimlanes,
    Table,
    Timeline,
    Wiki
  }

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Swimlanes.Config

  # Recomputes the user's permissions after the board reloads (grants may
  # have changed). Returns the socket, redirected away if access was lost.
  def assign_access(socket) do
    %{board: board, current_user: user} = socket.assigns
    perm = Access.board_permission(user, board)
    card = socket.assigns[:card]

    card_only =
      perm == :none and match?(%Card{}, card) and
        Access.can_read?(Access.card_permission(user, card))

    if perm == :none and not card_only do
      socket
      |> put_flash(:error, "Your access to that board was removed.")
      |> push_navigate(to: ~p"/")
    else
      socket
      |> assign(
        perm: perm,
        can_write: Access.can_write?(perm),
        can_manage: perm == :owner,
        view_only: perm == :view,
        card_only: card_only,
        allowed_views: Access.accessible_views(user, board)
      )
      |> assign_card_access()
    end
  end

  # Whether the open card is the reader's to see; when it isn't, the panel
  # closes. What they may do with it is `BoardLive.CardComponent`'s to decide.
  def assign_card_access(%{assigns: %{card: %Card{} = card}} = socket) do
    %{current_user: user, view_only: view_only, swim: config, swim_view: view} = socket.assigns
    {readable, _writable} = card_access(card, user, view_only, config, view)

    if readable do
      socket
    else
      socket
      |> assign(card: nil)
      |> put_flash(:error, "You don't have access to that card.")
      |> push_patch(to: socket.assigns.paths.close)
    end
  end

  def assign_card_access(socket), do: socket

  def assign_paths(socket) do
    assigns = socket.assigns

    paths =
      Map.new([:close, :tags, :activity, :archive, :settings, :automations], fn panel ->
        {panel, panel_path(assigns, panel)}
      end)

    paths = if assigns[:card_only], do: %{paths | close: ~p"/"}, else: paths
    assign(socket, paths: paths)
  end

  # The URL is the source of truth: `?view=ID` loads a saved view as the base
  # config and any other params override it (so the URL only carries what
  # differs from the saved view, or from the defaults when there is no view).
  def assign_swimlanes(socket, params) do
    board = socket.assigns.board
    view = find_view(board, params["view"])

    socket =
      if params["view"] && is_nil(view) do
        socket
        |> put_flash(:error, "That saved view no longer exists.")
        |> push_patch(to: mode_path(socket.assigns, []))
      else
        socket
      end

    base = if view, do: Config.from_map(view.config), else: Config.defaults(mode_name(socket))
    config = params |> Config.from_query(base) |> Config.sanitize(board)
    assign_swim_state(socket, view, base, config)
  end

  def assign_swim_state(socket, view, base, config) do
    # The board's own hidden facets go on both, so they never make a view dirty.
    hidden = Board.hidden_facets(socket.assigns.board)
    {base, config} = {Config.hide(base, hidden), Config.hide(config, hidden)}

    socket
    |> assign(
      swim_view: view,
      swim_base: base,
      swim: config,
      # Paging a timeline or calendar (the anchor date) doesn't modify a view.
      swim_dirty: not is_nil(view) and %{config | date: nil} != %{base | date: nil},
      swim_query: swim_query(view, config, base),
      view_grants: if(view && socket.assigns.can_manage, do: Access.list_grants(view), else: [])
    )
    |> assign_grid()
  end

  def swim_query(view, config, base) do
    if(view, do: [view: view.id], else: []) ++ Config.to_query(config, base)
  end

  def find_view(_board, nil), do: nil

  def find_view(board, id) do
    Enum.find(board.saved_views, &(to_string(&1.id) == to_string(id)))
  end

  def assign_grid(%{assigns: %{mode: :swimlanes, board: board, swim: config}} = socket) do
    assign(socket, grid: Swimlanes.grid(board, config))
  end

  def assign_grid(%{assigns: %{mode: :table, board: board, swim: config}} = socket) do
    rows = Table.rows(board, config)
    assign(socket, table_rows: rows, grid: %{shown: rows.shown, hidden: rows.hidden})
  end

  def assign_grid(%{assigns: %{mode: :timeline, board: board, swim: config}} = socket) do
    timeline = Timeline.build(board, config)

    assign(socket,
      timeline: timeline,
      grid: %{shown: timeline.shown, hidden: timeline.hidden, levels: timeline.levels}
    )
  end

  def assign_grid(%{assigns: %{mode: :calendar, board: board, swim: config}} = socket) do
    calendar = Slipdock.Calendar.build(board, config)
    assign(socket, calendar: calendar, grid: %{shown: calendar.shown, hidden: calendar.hidden})
  end

  def assign_grid(%{assigns: %{mode: :outline, board: board, swim: config}} = socket) do
    outline = Outline.build(board, board.rollup, config)

    assign(socket,
      outline: outline,
      grid: %{shown: outline.shown, hidden: outline.hidden, levels: outline.levels}
    )
  end

  def assign_grid(%{assigns: %{mode: :narrative, board: board, swim: config}} = socket) do
    narrative = Narrative.build(board, config)

    assign(socket,
      narrative: narrative,
      grid: %{shown: narrative.shown, hidden: narrative.hidden}
    )
  end

  def assign_grid(%{assigns: %{mode: :prioritise, board: board, swim: config}} = socket) do
    prioritise = Prioritise.build(board, config, socket.assigns.current_user)

    assign(socket,
      prioritise: prioritise,
      grid: %{shown: prioritise.shown, hidden: prioritise.hidden}
    )
  end

  def assign_grid(socket), do: socket

  # After the board reloads: pick up changes to the loaded saved view (or drop
  # it if it was deleted) and rebuild the grid.
  def refresh_swimlanes(socket) do
    %{board: board, swim_view: view, swim: config} = socket.assigns
    current = view && Enum.find(board.saved_views, &(&1.id == view.id))
    defaults = Config.defaults(mode_name(socket))

    if view && is_nil(current) do
      socket
      |> assign_swim_state(nil, defaults, Config.sanitize(config, board))
      |> assign_paths()
      |> push_patch(to: mode_path(socket.assigns, Config.to_query(config, defaults)))
    else
      base = if current, do: Config.from_map(current.config), else: defaults

      socket
      |> assign_swim_state(current, base, Config.sanitize(config, board))
      |> assign_paths()
    end
  end

  def patch_swim(socket, %Config{} = config) do
    %{swim_view: view, swim_base: base} = socket.assigns
    push_patch(socket, to: mode_path(socket.assigns, swim_query(view, config, base)))
  end

  def mode_name(%{assigns: %{mode: :board}}), do: "board"

  def mode_name(%{assigns: %{mode: :table}}), do: "table"

  def mode_name(%{assigns: %{mode: :timeline}}), do: "timeline"

  def mode_name(%{assigns: %{mode: :calendar}}), do: "calendar"

  def mode_name(%{assigns: %{mode: :outline}}), do: "outline"

  def mode_name(%{assigns: %{mode: :narrative}}), do: "narrative"

  def mode_name(%{assigns: %{mode: :prioritise}}), do: "prioritise"

  def mode_name(_), do: "swimlanes"

  def move_placed_page(socket, page_id, column_id, before) do
    with {:ok, page} <- Wiki.find_page(page_id),
         true <- Access.can_write?(Access.page_permission(socket.assigns.current_user, page)),
         {:ok, _} <- Wiki.place(page, column_id, before) do
      {:noreply, reload_board(socket)}
    else
      {:error, _, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "That page couldn't be moved.")}
    end
  end

  def reload_board(socket) do
    board = Boards.get_board!(socket.assigns.board.id)

    socket
    |> assign(board: board, page_title: board.name, ancestry: Boards.ancestry(board))
    |> assign_columns()
    |> assign_access()
  end

  # Whatever the drag or the menu named: a card, or a wiki page placed on the
  # board. `page-7` is a page; a bare number is a card.
  def load_item(board, id) do
    case Boards.item_ref(id) do
      {:card, card_id} -> load_card(board, card_id)
      {:page, page_id} -> load_placed_page(board, page_id)
      nil -> :error
    end
  end

  # A card and a placed wiki page are moved, edited and tagged through their
  # own contexts; the swimlane grid asks for the same three things of either.
  # Whatever the row named, if the reader may change it.
  def writable_item(socket, id) do
    case Boards.item_ref(id) do
      {:card, card_id} ->
        writable_card(socket, card_id)

      {:page, page_id} ->
        with {:ok, page} <- load_placed_page(socket.assigns.board, page_id),
             true <- Access.can_write?(Access.page_permission(socket.assigns.current_user, page)) do
          {:ok, page}
        else
          _ -> :error
        end

      nil ->
        :error
    end
  end

  # Voting needs only a reader, and votes hang off a card or a page alike
  # (see `Slipdock.Boards.Owned`), so Prioritise votes on whichever the row is.
  def readable_item(socket, id) do
    %{current_user: user, board: board, view_only: view_only} = socket.assigns

    case Boards.item_ref(id) do
      {:card, card_id} ->
        with %Card{} = card <- Boards.get_card(card_id),
             true <- in_tree?(socket, card),
             true <-
               if(view_only,
                 do: Swimlanes.matches?(card, socket.assigns.swim),
                 else: Access.can_read?(Access.card_permission(user, card))
               ) do
          {:ok, card}
        else
          _ -> :error
        end

      {:page, page_id} ->
        with {:ok, page} <- load_placed_page(board, page_id),
             true <- view_only or Access.can_read?(Access.page_permission(user, page)) do
          {:ok, page}
        else
          _ -> :error
        end

      nil ->
        :error
    end
  end

  def move_in_list(%Slipdock.Wiki.Page{} = page, column_id, before),
    do: Wiki.place(page, column_id, before)

  def move_in_list(card, column_id, before), do: Boards.move_card(card.id, column_id, before)

  # A page has one assignee: given a set, it takes the first.
  def update_item(%Slipdock.Wiki.Page{} = page, %{"assignee_ids" => ids} = attrs),
    do:
      update_item(
        page,
        attrs |> Map.delete("assignee_ids") |> Map.put("assignee_id", List.first(ids))
      )

  def update_item(%Slipdock.Wiki.Page{} = page, attrs),
    do: Wiki.update_page(Wiki.get_page!(page.id), attrs)

  def update_item(card, attrs), do: Boards.update_card(Boards.get_card!(card.id), attrs)

  def set_item_tags(%Slipdock.Wiki.Page{} = page, tags), do: Wiki.set_tags(page, tags)

  def set_item_tags(card, tags), do: Boards.set_card_tags(card, tags)

  def assign_columns(socket) do
    %{board: board, filters: filters} = socket.assigns

    columns =
      Enum.map(board.columns, fn col ->
        visible = Enum.filter(col.cards, &Slipdock.Filters.matches?(&1, filters))
        # A draft the reader couldn't have written was never theirs to see, so
        # it is not something the filters are hiding.
        readable = Enum.filter(col.pages, &page_visible?(&1, socket))
        pages = Enum.filter(readable, &Slipdock.Filters.matches?(&1, filters))

        # Cards and placed pages share one position sequence, so the list
        # is drawn from a single ordering rather than one after the other —
        # then in the list's own order and groups, if it has them.
        groups = arrange(interleave(visible, pages), col, board)
        items = Enum.flat_map(groups, & &1.items)

        %{
          column: col,
          # In drawing order, so the keyboard walks the list as it looks.
          cards: for({:card, card} <- items, do: card),
          pages: pages,
          items: items,
          groups: groups,
          hidden: length(col.cards) - length(visible) + (length(readable) - length(pages))
        }
      end)

    assign(socket, columns: columns, filtering: Slipdock.Filters.any?(filters))
  end

  defp arrange(items, column, board) do
    items
    |> Enum.map(&elem(&1, 1))
    |> Slipdock.ListOrder.arrange(column, board)
    |> Enum.map(fn group -> %{group | items: Enum.map(group.items, &kind/1)} end)
  end

  defp kind(%Slipdock.Wiki.Page{} = page), do: {:page, page}
  defp kind(card), do: {:card, card}

  def interleave(cards, pages) do
    items =
      Enum.map(cards, &{&1.position, 0, {:card, &1}}) ++
        Enum.map(pages, &{&1.board_position, 1, {:page, &1}})

    items |> Enum.sort() |> Enum.map(&elem(&1, 2))
  end

  # A placed page carries the card facets, so it answers the same filters a
  # card does. The only question that is its own is whether the reader should
  # see it at all: a draft is for people who could have written it.
  def page_visible?(page, socket), do: page.status != "draft" or socket.assigns.can_write

  def put_filter(socket, key, value) do
    socket |> assign(filters: Map.put(socket.assigns.filters, key, value)) |> assign_columns()
  end

  def swim_attrs(ops) do
    Enum.reduce(ops, %{}, fn
      {:attrs, attrs}, acc -> Map.merge(acc, attrs)
      _, acc -> acc
    end)
  end

  def swim_tag_ids(ops),
    do:
      Enum.find_value(ops, fn
        {:tags, ids} -> ids
        _ -> nil
      end)

  def board_tags(board, ids), do: Enum.filter(board.tags, &(&1.id in ids))

  # The board's readers that this user can see. A page's current assignee is
  # added back where it is shown (`assignee_options/2`), so a facet form that
  # re-posts every field never unassigns somebody by leaving them out.
  def assignable_users(board, user) do
    visible = user |> Access.visible_user_ids() |> MapSet.new()
    board |> Wiki.members() |> Enum.filter(&MapSet.member?(visible, &1.id))
  end

  def refresh_assignable(socket) do
    %{board: board, current_user: user} = socket.assigns

    assign(socket,
      assignable: assignable_users(board, user),
      mention_people: SlipdockWeb.Mention.people(board)
    )
  end

  # A card on this board (or one of its sub-boards) the user may edit.
  # Whether a card is on this board or any board beneath it.
  def in_tree?(%{assigns: %{board: board}}, card),
    do: card.board_id == board.id or Slipdock.Rollup.member?(board.rollup, card)

  # A card on this board's tree the user may edit. Off the tree it is :error
  # whatever the user's rights to it: a view's grant covers the cards of this
  # board that match it, not every card on the server.
  def writable_card(socket, id) do
    %{current_user: user, view_only: view_only, swim: config, swim_view: view} = socket.assigns

    with %Card{} = card <- Boards.get_card(id),
         true <- in_tree?(socket, card),
         true <-
           if(view_only,
             do:
               Swimlanes.matches?(card, config) and
                 Access.can_write?(Access.view_permission(user, view)),
             else: Access.can_write?(Access.card_permission(user, card))
           ) do
      {:ok, card}
    else
      _ -> :error
    end
  end

  # The list `id` on the open board, or nil.
  def board_column(socket, id), do: Boards.get_board_column(socket.assigns.board.id, id)
end

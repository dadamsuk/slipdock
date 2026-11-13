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
  alias Slipdock.CardViews
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
    {readable, _level} = card_access(card, user, view_only, config, view)

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

  @doc "The board's Agentic Building page (#2011), or nil while its switch is off."
  def agentic_path(board) do
    if Slipdock.AgenticBuilding.on?(board), do: ~p"/boards/#{board}/agentic"
  end

  def assign_paths(socket) do
    assigns = socket.assigns

    paths =
      Map.new([:close, :tags, :activity, :archive, :settings, :automations], fn panel ->
        {panel, panel_path(assigns, panel)}
      end)

    # The Tidy-up page is a page of its own, whatever the view (W-1807).
    paths = Map.put(paths, :tidy, ~p"/boards/#{assigns.board}/tidy")
    # Agentic Building (#2011): a page of its own too, only while it is on.
    paths = Map.put(paths, :agentic, agentic_path(assigns.board))
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
    # What the reader's card views put on each list's cards (#2031), on both,
    # so a card view never makes a saved view dirty either.
    card_view = card_view(socket, config)
    front = card_front(card_view, socket.assigns.board, config.density)
    show_all = card_view.show_all

    {base, config} =
      {Config.put_front(base, front, show_all), Config.put_front(config, front, show_all)}

    socket
    |> assign(
      card_view: card_view,
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

  @doc """
  Resolves the reader's card views on the board into `:card_views` (#2031),
  at mount and whenever they change. The saved view's own card view goes on
  top in `assign_swim_state/4`.
  """
  def assign_card_views(%{assigns: assigns} = socket) do
    assign(socket,
      card_views: CardViews.resolve(assigns.current_user, assigns.board),
      card_view_names: Enum.map(CardViews.list(assigns.current_user), & &1.name)
    )
  end

  # The resolved card views, with the card view an open saved view (or the
  # URL's `card_view=`) names on top.
  defp card_view(%{assigns: assigns}, config) do
    resolved = assigns[:card_views] || CardViews.resolve(assigns.current_user, assigns.board)

    case Config.card_view(config) do
      name when is_binary(name) -> CardViews.with_saved_view(resolved, assigns.current_user, name)
      nil -> resolved
    end
  end

  # Each list's card front, and the board's (`nil`) for cards drawn apart
  # from a list. A list's own settings (no age chip, no front image) win.
  defp card_front(resolved, board, density) do
    lists =
      for column <- board.columns, into: %{} do
        shown = CardViews.front_shown(resolved, column.id, density)
        {column.id, MapSet.difference(shown, MapSet.new(CardViews.list_hidden(column)))}
      end

    Map.put(lists, nil, CardViews.front_shown(resolved, nil, density))
  end

  def swim_query(view, config, base) do
    if(view, do: [view: view.id], else: []) ++ Config.to_query(config, base)
  end

  def find_view(_board, nil), do: nil

  def find_view(board, id) do
    Enum.find(board.saved_views, &(to_string(&1.id) == to_string(id)))
  end

  # Snoozed cards (W-1803): the calendar and the timeline draw them by their
  # own dates, faded; the grid views only when "Show snoozed" is on.
  defp view_board(board, mode, _config) when mode in [:calendar, :timeline],
    do: Slipdock.Snooze.with_snoozed(board)

  defp view_board(board, _mode, %{snoozed: "show"}), do: Slipdock.Snooze.with_snoozed(board)
  defp view_board(board, _mode, _config), do: board

  def assign_grid(%{assigns: %{mode: :swimlanes, board: board, swim: config}} = socket) do
    assign(socket, grid: Swimlanes.grid(view_board(board, :swimlanes, config), config))
  end

  def assign_grid(%{assigns: %{mode: :table, board: board, swim: config}} = socket) do
    rows = Table.rows(view_board(board, :table, config), config)
    assign(socket, table_rows: rows, grid: %{shown: rows.shown, hidden: rows.hidden})
  end

  def assign_grid(%{assigns: %{mode: :timeline, board: board, swim: config}} = socket) do
    timeline = Timeline.build(view_board(board, :timeline, config), config)

    assign(socket,
      timeline: timeline,
      grid: %{shown: timeline.shown, hidden: timeline.hidden, levels: timeline.levels}
    )
  end

  def assign_grid(%{assigns: %{mode: :calendar, board: board, swim: config}} = socket) do
    calendar = Slipdock.Calendar.build(view_board(board, :calendar, config), config)
    assign(socket, calendar: calendar, grid: %{shown: calendar.shown, hidden: calendar.hidden})
  end

  def assign_grid(%{assigns: %{mode: :outline, board: board, swim: config}} = socket) do
    outline = Outline.build(view_board(board, :outline, config), board.rollup, config)

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

  def move_placed_page(socket, page_id, column_id, before, from \\ nil) do
    with {:ok, page} <- Wiki.find_page(page_id),
         true <- Access.can_write?(Access.page_permission(socket.assigns.current_user, page)),
         false <- moved_since_drawn?(from, page.column_id),
         {:ok, _} <- Wiki.place(page, column_id, before) do
      {:noreply, reload_board(socket)}
    else
      true ->
        {:noreply, moved_since_drawn(socket)}

      {:error, _, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "That page couldn't be moved.")}
    end
  end

  @doc """
  Whether a move's `from` (the list the tab drew the item in) is no longer
  where the item is (#1921). A move that names no `from` isn't stale.
  """
  def moved_since_drawn?(nil, _current), do: false
  def moved_since_drawn?(from, current), do: SlipdockWeb.Params.id(from) != current

  @doc "Refuses a stale move: says so and redraws the board as it is now."
  def moved_since_drawn(socket) do
    socket
    |> reload_board()
    |> put_flash(
      :error,
      "That has moved since this board was drawn, so it stayed where it is. The board is up to date now."
    )
  end

  def reload_board(socket) do
    board =
      Access.hide_unreadable_dependencies(
        socket.assigns.current_user,
        Boards.get_board!(socket.assigns.board.id)
      )

    socket
    |> assign(board: board, page_title: board.name, ancestry: Boards.ancestry(board))
    |> assign(pulse: board_pulse(board), pauses: board_pauses(board))
    |> assign_waiting_tree()
    # Deploys move the delivery strip themselves; a reload only follows
    # the switch.
    |> assign(
      dora: (board.delivery_metrics && (socket.assigns[:dora] || board_dora(board))) || nil
    )
    |> assign_columns()
    |> assign_access()
  end

  @doc """
  Where a batched tree's releases stand (#2835), for the banner; nil on any
  other, and for someone who can't read the tree's root board, whose cards
  it counts.
  """
  def board_release(board, user) do
    if Slipdock.Releases.batched?(board) and reads_root?(board, user),
      do: Slipdock.Releases.status(board)
  end

  defp reads_root?(%Board{} = board, user),
    do: Access.can_read?(Access.board_permission(user, Boards.root_board(board)))

  @doc """
  The open runner pauses on the board's tree (#1116), each with the root
  board it is kept on, for the banner every board in the tree shows.
  """
  def board_pauses(board) do
    case Slipdock.Runners.pauses(board) do
      [] ->
        []

      pauses ->
        root = Slipdock.Boards.root_board(board)

        Enum.map(pauses, &%{pause: &1, root: root})
    end
  end

  @doc "The board's pulse for its strip (#1113), worked out only when the strip is on."
  def board_pulse(%{show_pulse: true} = board), do: Slipdock.Pulse.for_board(board)
  def board_pulse(_board), do: nil

  @doc "The board's delivery numbers for its strip (#1134), only while its delivery metrics are on."
  def board_dora(%{delivery_metrics: true} = board) do
    case Slipdock.Dora.for_board(board) do
      {:ok, report} -> report
      {:error, :off} -> nil
    end
  end

  def board_dora(_board), do: nil

  # Whatever the drag or the menu named: a card, or a wiki page placed on the
  # board. `page-7` is a page; a bare number is a card.
  def load_item(board, id) do
    case Boards.Columns.item_ref(id) do
      {:card, card_id} -> load_card(board, card_id)
      {:page, page_id} -> load_placed_page(board, page_id)
      nil -> :error
    end
  end

  # A card and a placed wiki page are moved, edited and tagged through their
  # own contexts; the swimlane grid asks for the same three things of either.
  # Whatever the row named, if the reader may change it.
  def writable_item(socket, id) do
    case Boards.Columns.item_ref(id) do
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

    case Boards.Columns.item_ref(id) do
      {:card, card_id} ->
        with %Card{} = card <- Boards.Cards.get_card(card_id),
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

  def move_in_list(item, column_id, before, user)

  def move_in_list(%Slipdock.Wiki.Page{} = page, column_id, before, _user),
    do: Wiki.place(page, column_id, before)

  def move_in_list(card, column_id, before, user),
    do: Boards.Cards.move_card(card.id, column_id, before, actor: Slipdock.Actor.web(user))

  # A page has one assignee: given a set, it takes the first.
  def update_item(%Slipdock.Wiki.Page{} = page, %{"assignee_ids" => ids} = attrs),
    do:
      update_item(
        page,
        attrs |> Map.delete("assignee_ids") |> Map.put("assignee_id", List.first(ids))
      )

  def update_item(%Slipdock.Wiki.Page{} = page, attrs),
    do: Wiki.update_page(Wiki.get_page!(page.id), attrs)

  def update_item(card, attrs),
    do: Boards.Cards.update_card(Boards.Cards.get_card!(card.id), attrs)

  def set_item_tags(%Slipdock.Wiki.Page{} = page, tags), do: Wiki.set_tags(page, tags)

  def set_item_tags(card, tags), do: Boards.Cards.set_card_tags(card, tags)

  @doc """
  What in the board's tree waits on the reader (#2095, `Slipdock.Work.Tree`):
  `:waiting_tree`, for the header's count and each epic's chip and glance
  line. Worked out again on every reload, so it follows a wait opened or
  answered anywhere below.
  """
  def assign_waiting_tree(socket) do
    assign(socket,
      waiting_tree:
        Slipdock.Work.Tree.for_board(socket.assigns.current_user, socket.assigns.board)
    )
  end

  def assign_columns(socket) do
    %{board: board, filters: filters} = socket.assigns
    tree = socket.assigns[:waiting_tree] || %Slipdock.Work.Tree{}
    waiting = waiting_keep(socket.assigns[:waiting_filter], tree, board)
    in_view = view_keep(socket.assigns)

    columns =
      Enum.map(board.columns, fn col ->
        col = %{
          col
          | cards: Enum.filter(col.cards, in_view),
            snoozed: Enum.filter(col.snoozed, in_view)
        }

        cards = Enum.map(col.cards, &%{&1 | waiting_on_me: Slipdock.Work.Tree.of(tree, &1.id)})

        visible =
          Enum.filter(cards, &(Slipdock.Filters.matches?(&1, filters) and waiting.(&1)))

        # A draft the reader couldn't have written was never theirs to see, so
        # it is not something the filters are hiding.
        # A saved view keeps its placed pages to its settings too, as it does
        # its cards.
        readable = Enum.filter(col.pages, &(page_visible?(&1, socket) and in_view.(&1)))

        pages =
          Enum.filter(
            readable,
            &(Slipdock.Filters.matches?(&1, filters) and socket.assigns[:waiting_filter] != true)
          )

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
          # Snoozed (W-1803): counted in the list's footer, which shows them.
          snoozed: Enum.filter(col.snoozed, &Slipdock.Filters.matches?(&1, filters)),
          hidden: length(col.cards) - length(visible) + (length(readable) - length(pages))
        }
      end)

    filtering = Slipdock.Filters.any?(filters) or socket.assigns[:waiting_filter] == true
    socket = assign(socket, columns: columns, filtering: filtering)

    # With nothing filtered, the next search starts as the grouped list
    # again, its folds at their defaults (#2809).
    if filtering, do: socket, else: SlipdockWeb.BoardLive.SearchResults.reset(socket)
  end

  # `?waiting=me` (#2095): only the cards with something on the reader on
  # them or beneath them, as an epic's chip opens its sub-board.
  defp waiting_keep(true, tree, board) do
    ids = Slipdock.Work.Tree.card_ids(tree, board)
    &MapSet.member?(ids, &1.id)
  end

  defp waiting_keep(_, _tree, _board), do: fn _ -> true end

  # A reader whose access is a saved view sees the cards that view shows, in
  # every mode, and none until a view granted to them is loaded. The view's
  # saved settings decide it, not the address's changes to them.
  defp view_keep(%{view_only: true} = assigns) do
    %{swim_view: view, swim_base: base, allowed_views: allowed} = assigns

    if view && Enum.any?(allowed, &(&1.id == view.id)),
      do: &Swimlanes.matches?(&1, base),
      else: fn _ -> false end
  end

  defp view_keep(_assigns), do: fn _ -> true end

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

  def board_tags(board, ids), do: Enum.filter(board.tags, &Enum.member?(ids, &1.id))

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

    with %Card{} = card <- Boards.Cards.get_card(id),
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
  def board_column(socket, id), do: Boards.Columns.get_board_column(socket.assigns.board.id, id)
end

defmodule SlipdockWeb.BoardLive.Show do
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.SwimlaneComponents
  import SlipdockWeb.TableComponents
  import SlipdockWeb.TimelineComponents
  import SlipdockWeb.CalendarComponents
  import SlipdockWeb.OutlineComponents
  import SlipdockWeb.NarrativeComponents
  import SlipdockWeb.PrioritiseComponents
  import SlipdockWeb.BoardLive.Paths
  import SlipdockWeb.BoardLive.Helpers
  import SlipdockWeb.BoardLive.Items
  import SlipdockWeb.BoardLive.BoardView

  alias Slipdock.{
    Access,
    Accounts,
    Automations,
    Boards,
    Favourites,
    Fields,
    Narrative,
    Outline,
    Sprints,
    Swimlanes,
    Timeline,
    Votes,
    Wiki
  }

  alias Slipdock.Prioritise

  alias Slipdock.Boards.{
    Attachment,
    Board,
    Card,
    Column,
    FieldDefinition
  }

  alias SlipdockWeb.Params
  alias SlipdockWeb.BoardLive.Sharing
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Table

  @empty_filters Slipdock.Filters.empty()

  ## Lifecycle ---------------------------------------------------------------

  # Every event is in one of the lists below, and one that is in none of them
  # is refused (see the guards at the top of `handle_event/3`). A handler
  # nobody remembered to classify fails closed — it does nothing — instead of
  # running for anyone who can open the board, which is how a pushEvent with
  # somebody else's card id once reached `delete_archived`.
  #
  # And whichever list it is in, a handler that takes an id from the client
  # proves that id is on this board (or the open card) before using it: write
  # access here is no reason to touch a row on another board.

  # Events that change the board; refused with read-only access.
  @board_write_events ~w(add_column rename_column move_column quick_add_card move_card place_page focus_move
    focus_hold focus_add swim_move swim_quick_add cal_quick_add swim_save_view
    swim_update_view swim_rename_view swim_delete_view)
  # Events whose handler checks the permission itself, because what it acts
  # on is not the open board or the open card: a card named by id, a page,
  # another board, a sprint picked from several boards.
  @self_checked_events ~w(share revoke_grant toggle_complete table_update prio_field prio_vote timeline_move
    timeline_schedule cal_move toggle_favourite)
  # Events that change nothing stored: filters, panels opening and closing,
  # forms being typed into, the keyboard's place on the board.
  @read_events ~w(search filter_tag filter_kind filter_priority filter_flag filter_due
    toggle_hide_completed clear_filters start_add_column cancel_add_column
    start_rename_column cancel_rename_column start_add_card aim_document cancel_add_card
    quick_add_change open_card open_page focus_column focus_card focus_open focus_end
    validate_document swim_config swim_set swim_clear_filters table_sort cal_toggle_day
    swim_toggle_row swim_start_add swim_cancel_add)

  # Events only the board owner may perform.
  @owner_events ~w(swim_publish_view swim_unpublish_view)

  @known_events @owner_events ++ @board_write_events ++ @self_checked_events ++ @read_events

  @doc false
  # For the test that every `handle_event/3` clause is in one of the lists.
  def known_events, do: @known_events

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    board = Boards.get_board!(id)
    user = socket.assigns.current_user
    perm = Access.board_permission(user, board)
    # A card shared on its own: the board stays hidden, only that card opens.
    card_only = perm == :none and card_readable?(user, board, params["card_id"])

    if perm == :none and not card_only do
      {:ok,
       socket
       |> put_flash(:error, "You don't have access to that board.")
       |> push_navigate(to: ~p"/")}
    else
      if connected?(socket) do
        Boards.subscribe(board.id)
        Boards.subscribe_templates()
        Automations.subscribe_callbacks(board.id)
      end

      {:ok,
       socket
       |> assign(
         perm: perm,
         can_write: Access.can_write?(perm),
         can_manage: perm == :owner,
         view_only: perm == :view,
         card_only: card_only,
         allowed_views: Access.accessible_views(user, board),
         groups: Accounts.list_groups(user),
         # The placed wiki page whose panel is open (`?page=`); the panel
         # itself is `BoardLive.PageComponent`.
         page_id: nil,
         view_grants: [],
         share_key: 0
       )
       |> mount_assigns(board)}
    end
  end

  defp mount_assigns(socket, board) do
    socket
    |> assign(
      board: board,
      page_title: board.name,
      # Who `@` offers in a description or a comment: the board's members.
      mention_people: SlipdockWeb.Mention.people(board),
      filters: @empty_filters,
      adding_to: nil,
      # The list a document dropped on the board belongs to: set the moment
      # the file picker opens, because the upload itself carries no column.
      document_column: nil,
      adding_column: false,
      focus: nil,
      page_jumps: [],
      renaming_column: nil,
      form_key: 0,
      card: nil,
      mode: :board,
      panel: nil,
      paths: %{},
      swim: %Config{},
      swim_base: %Config{},
      swim_view: nil,
      swim_dirty: false,
      swim_query: [],
      swim_collapsed: MapSet.new(),
      swim_adding: nil,
      grid: nil,
      table_rows: nil,
      timeline: nil,
      calendar: nil,
      outline: nil,
      narrative: nil,
      prioritise: nil,
      cal_expanded: MapSet.new(),
      ancestry: Boards.ancestry(board),
      templates: Boards.list_templates(),
      users: Access.visible_users(socket.assigns.current_user),
      # Who the card and page pickers offer: only people who could be put on
      # one (see `Boards.resolve_assignees/3`), not everybody in the directory.
      assignable: assignable_users(board, socket.assigns.current_user),
      quick_preview: %{},
      # Whether `BoardLive.MoveBoardComponent` has its picker open.
      moving_board: false,
      # Whether `BoardLive.SprintComponent` has its picker open.
      sprint_picking: false,
      sprint_of: Sprints.sprint_of_board(board),
      favourites: Favourites.marks(socket.assigns.current_user),
      # The count beside Automations in the menu; the panel itself is
      # `BoardLive.AutomationsComponent`, which keeps this up to date.
      rules: [],
      ai?: Slipdock.AI.configured?(socket.assigns.current_user)
    )
    |> assign_columns()
    |> allow_uploads()
  end

  # A file dropped at the foot of a list: a card of its own, named after the
  # file, with the file attached. (A card's own uploads are the card panel's,
  # `BoardLive.CardComponent`.)
  defp allow_uploads(socket) do
    allow_upload(socket, :list_document,
      accept: :any,
      max_entries: 5,
      max_file_size: Attachment.max_size(),
      auto_upload: true,
      progress: &handle_upload/3
    )
  end

  # Called as each chunk lands; stores the file once the whole upload is in.
  # A file dropped at the foot of a list becomes a card of its own: named
  # after the file, with the file attached. "Add a document" is a shortcut to
  # adding a card, not a fourth kind of thing on the board.
  defp handle_upload(:list_document, entry, socket) do
    column =
      Enum.find(socket.assigns.board.columns, &(&1.id == socket.assigns.document_column))

    cond do
      not entry.done? ->
        {:noreply, socket}

      # Never fail quietly here: a file that vanishes without a word is
      # indistinguishable from a button that does nothing.
      is_nil(column) or not socket.assigns.can_write ->
        {:noreply,
         socket
         |> cancel_upload(:list_document, entry.ref)
         |> put_flash(:error, "Couldn't tell which list that file was for — try again.")}

      true ->
        meta = %{
          filename: entry.client_name,
          content_type: entry.client_type,
          size: entry.client_size
        }

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            with {:ok, card} <- Boards.create_card(column, %{"title" => document_title(entry)}),
                 {:ok, _} <- Boards.add_attachment(card, meta, path) do
              {:ok, {:ok, card}}
            else
              other -> {:ok, other}
            end
          end)

        case result do
          {:ok, card} ->
            {:noreply,
             socket
             |> put_flash(:info, "Added “#{card.title}” to #{column.name}.")
             |> reload_board()}

          _ ->
            {:noreply,
             socket |> put_flash(:error, "Couldn't put that file on the board.") |> reload_board()}
        end
    end
  end

  # A file's name is a fair card title; the extension is not part of it.
  defp document_title(entry) do
    case entry.client_name |> Path.basename() |> Path.rootname() |> String.trim() do
      "" -> entry.client_name
      title -> String.slice(title, 0, 200)
    end
  end

  defp card_readable?(_user, _board, nil), do: false

  defp card_readable?(user, board, card_id) do
    case load_card(board, card_id) do
      {:ok, card} -> Access.can_read?(Access.card_permission(user, card))
      :error -> false
    end
  end

  # Recomputes the user's permissions after the board reloads (grants may
  # have changed). Returns the socket, redirected away if access was lost.
  defp assign_access(socket) do
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
  defp assign_card_access(%{assigns: %{card: %Card{} = card}} = socket) do
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

  defp assign_card_access(socket), do: socket

  defp page_panel_path(socket, id),
    do: append_query(socket.assigns.paths.close, page: id)

  @impl true
  def handle_params(params, _uri, socket) do
    {mode, panel} = split_action(socket.assigns.live_action)
    socket = assign(socket, mode: mode, panel: panel)

    # Leaving the board view, or opening a card, ends whatever the keyboard held.
    socket = if mode == :board and is_nil(panel), do: socket, else: assign(socket, focus: nil)

    socket =
      socket
      |> assign_swimlanes(params)
      |> assign_paths()
      |> assign_page_jumps()
      |> apply_panel(panel, params)
      # `?page=<id>` opens a placed wiki page's panel over whatever view you
      # are on. A query parameter rather than a route because it has to work
      # in all eight modes, and a route each would be eight more.
      |> assign(page_id: params["page"])

    if socket.assigns.view_only and is_nil(socket.redirected) do
      {:noreply, enforce_view_only(socket, params)}
    else
      {:noreply, scroll_to_list(socket, params["list"])}
    end
  end

  # `?list=<id>` arrives from a favourited list (see `Slipdock.Favourites`).
  # The board is wider than the screen — a phone shows one list at a time —
  # so opening it at the list you asked for is the difference between two
  # taps and two taps plus a swipe hunt. The browser does the scrolling; the
  # server only says which one.
  defp scroll_to_list(socket, nil), do: socket

  defp scroll_to_list(socket, id) do
    if Enum.any?(socket.assigns.board.columns, &(to_string(&1.id) == id)),
      do: push_event(socket, "scroll-to-list", %{id: id}),
      else: socket
  end

  # With view-only access the board is reachable only through granted saved
  # views, in the mode each was saved in, with the view's own settings.
  defp enforce_view_only(socket, params) do
    %{allowed_views: allowed, board: board} = socket.assigns
    wanted = find_view(board, params["view"])

    view =
      if wanted && Enum.any?(allowed, &(&1.id == wanted.id)),
        do: wanted,
        else: List.first(allowed)

    cond do
      is_nil(view) ->
        socket
        |> put_flash(:error, "No views of that board are shared with you.")
        |> push_navigate(to: ~p"/")

      socket.assigns.swim_view == nil or socket.assigns.swim_view.id != view.id or
          socket.assigns.swim_dirty ->
        push_patch(socket, to: view_path(board, view))

      true ->
        socket
    end
  end

  defp apply_panel(%{assigns: %{card_only: true}} = socket, nil, _),
    do: push_navigate(socket, to: ~p"/")

  defp apply_panel(socket, nil, _),
    do: assign(socket, card: nil)

  defp apply_panel(socket, :card, %{"card_id" => card_id}) do
    case load_card(socket.assigns.board, card_id) do
      {:ok, card} ->
        socket |> assign(card: card) |> assign_card_access()

      :error ->
        socket
        |> put_flash(:error, "That card no longer exists.")
        |> push_patch(to: socket.assigns.paths.close)
    end
  end

  defp apply_panel(socket, panel, _) when panel in [:activity, :archive], do: socket

  defp apply_panel(socket, :tags, _), do: socket

  defp apply_panel(socket, :automations, _), do: socket

  defp apply_panel(socket, :settings, _), do: socket

  ## Paths: every panel is reachable from both modes, and in swimlane mode
  ## the view configuration travels along in the query string.

  defp assign_paths(socket) do
    assigns = socket.assigns

    paths =
      Map.new([:close, :tags, :activity, :archive, :settings, :automations], fn panel ->
        {panel, panel_path(assigns, panel)}
      end)

    paths = if assigns[:card_only], do: %{paths | close: ~p"/"}, else: paths
    assign(socket, paths: paths)
  end

  ## Swimlane configuration ---------------------------------------------------

  # The URL is the source of truth: `?view=ID` loads a saved view as the base
  # config and any other params override it (so the URL only carries what
  # differs from the saved view, or from the defaults when there is no view).
  defp assign_swimlanes(socket, params) do
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

  defp assign_swim_state(socket, view, base, config) do
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

  defp swim_query(view, config, base) do
    if(view, do: [view: view.id], else: []) ++ Config.to_query(config, base)
  end

  defp find_view(_board, nil), do: nil

  defp find_view(board, id) do
    Enum.find(board.saved_views, &(to_string(&1.id) == to_string(id)))
  end

  defp assign_grid(%{assigns: %{mode: :swimlanes, board: board, swim: config}} = socket) do
    assign(socket, grid: Swimlanes.grid(board, config))
  end

  defp assign_grid(%{assigns: %{mode: :table, board: board, swim: config}} = socket) do
    rows = Table.rows(board, config)
    assign(socket, table_rows: rows, grid: %{shown: rows.shown, hidden: rows.hidden})
  end

  defp assign_grid(%{assigns: %{mode: :timeline, board: board, swim: config}} = socket) do
    timeline = Timeline.build(board, config)

    assign(socket,
      timeline: timeline,
      grid: %{shown: timeline.shown, hidden: timeline.hidden, levels: timeline.levels}
    )
  end

  defp assign_grid(%{assigns: %{mode: :calendar, board: board, swim: config}} = socket) do
    calendar = Slipdock.Calendar.build(board, config)
    assign(socket, calendar: calendar, grid: %{shown: calendar.shown, hidden: calendar.hidden})
  end

  defp assign_grid(%{assigns: %{mode: :outline, board: board, swim: config}} = socket) do
    outline = Outline.build(board, board.rollup, config)

    assign(socket,
      outline: outline,
      grid: %{shown: outline.shown, hidden: outline.hidden, levels: outline.levels}
    )
  end

  defp assign_grid(%{assigns: %{mode: :narrative, board: board, swim: config}} = socket) do
    narrative = Narrative.build(board, config)

    assign(socket,
      narrative: narrative,
      grid: %{shown: narrative.shown, hidden: narrative.hidden}
    )
  end

  defp assign_grid(%{assigns: %{mode: :prioritise, board: board, swim: config}} = socket) do
    prioritise = Prioritise.build(board, config, socket.assigns.current_user)

    assign(socket,
      prioritise: prioritise,
      grid: %{shown: prioritise.shown, hidden: prioritise.hidden}
    )
  end

  defp assign_grid(socket), do: socket

  # After the board reloads: pick up changes to the loaded saved view (or drop
  # it if it was deleted) and rebuild the grid.
  defp refresh_swimlanes(socket) do
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

  defp patch_swim(socket, %Config{} = config) do
    %{swim_view: view, swim_base: base} = socket.assigns
    push_patch(socket, to: mode_path(socket.assigns, swim_query(view, config, base)))
  end

  defp mode_name(%{assigns: %{mode: :board}}), do: "board"
  defp mode_name(%{assigns: %{mode: :table}}), do: "table"
  defp mode_name(%{assigns: %{mode: :timeline}}), do: "timeline"
  defp mode_name(%{assigns: %{mode: :calendar}}), do: "calendar"
  defp mode_name(%{assigns: %{mode: :outline}}), do: "outline"
  defp mode_name(%{assigns: %{mode: :narrative}}), do: "narrative"
  defp mode_name(%{assigns: %{mode: :prioritise}}), do: "prioritise"
  defp mode_name(_), do: "swimlanes"

  defp move_placed_page(socket, page_id, column_id, before) do
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

  defp reload_board(socket) do
    board = Boards.get_board!(socket.assigns.board.id)

    socket
    |> assign(board: board, page_title: board.name, ancestry: Boards.ancestry(board))
    |> assign_columns()
    |> assign_access()
  end

  # Whatever the drag or the menu named: a card, or a wiki page placed on the
  # board. `page-7` is a page; a bare number is a card.
  defp load_item(board, id) do
    case Boards.item_ref(id) do
      {:card, card_id} -> load_card(board, card_id)
      {:page, page_id} -> load_placed_page(board, page_id)
      nil -> :error
    end
  end

  # A card and a placed wiki page are moved, edited and tagged through their
  # own contexts; the swimlane grid asks for the same three things of either.
  # Whatever the row named, if the reader may change it.
  defp writable_item(socket, id) do
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
  defp readable_item(socket, id) do
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

  defp move_in_list(%Slipdock.Wiki.Page{} = page, column_id, before),
    do: Wiki.place(page, column_id, before)

  defp move_in_list(card, column_id, before), do: Boards.move_card(card.id, column_id, before)

  # A page has one assignee: given a set, it takes the first.
  defp update_item(%Slipdock.Wiki.Page{} = page, %{"assignee_ids" => ids} = attrs),
    do:
      update_item(
        page,
        attrs |> Map.delete("assignee_ids") |> Map.put("assignee_id", List.first(ids))
      )

  defp update_item(%Slipdock.Wiki.Page{} = page, attrs),
    do: Wiki.update_page(Wiki.get_page!(page.id), attrs)

  defp update_item(card, attrs), do: Boards.update_card(Boards.get_card!(card.id), attrs)

  defp set_item_tags(%Slipdock.Wiki.Page{} = page, tags), do: Wiki.set_tags(page, tags)
  defp set_item_tags(card, tags), do: Boards.set_card_tags(card, tags)

  ## Quick add ------------------------------------------------------------------

  defp quick_parse(socket, title, target) do
    Slipdock.QuickAdd.parse(title, socket.assigns.board,
      users: socket.assigns.users,
      columns: target.columns
    )
  end

  # Where the card goes: the board itself, or the sub-board of `parent_card`.
  # The wire sends a string; a caller with the id already in hand sends the
  # integer.
  defp column_id(id) when is_integer(id), do: id
  defp column_id(id), do: Params.id(id)

  defp quick_add_target(board, nil), do: {:ok, board, nil}
  defp quick_add_target(board, ""), do: {:ok, board, nil}

  defp quick_add_target(board, parent_id) do
    with %Card{} = card <- Boards.get_card(parent_id),
         true <- card.board_id == board.id or card.board_id in tree_board_ids(board),
         %{id: sub_id} <- card.sub_board do
      {:ok, Boards.get_board!(sub_id), card}
    else
      _ -> {:error, "That card has no subcards board."}
    end
  end

  defp tree_board_ids(%{rollup: %{boards: boards}}) when is_map(boards), do: Map.keys(boards)
  defp tree_board_ids(_), do: []

  # What a table group stands for, as swimlane ops (see Swimlanes.move_ops/5).
  defp quick_add_ops(_config, nil), do: {:ok, []}
  defp quick_add_ops(_config, ""), do: {:ok, []}

  defp quick_add_ops(config, key) do
    ops = Swimlanes.move_ops(config.rows, nil, nil, key, config)

    case Enum.find(ops, &match?({:error, _}, &1)) do
      {:error, message} -> {:error, message}
      nil -> {:ok, ops}
    end
  end

  defp quick_ops_column(board, ops) do
    Enum.find_value(ops, fn
      {:column, id} -> Enum.find(board.columns, &(&1.id == id))
      _ -> nil
    end)
  end

  defp quick_param_column(_board, nil), do: nil
  defp quick_param_column(_board, ""), do: nil

  defp quick_param_column(board, id),
    do: Enum.find(board.columns, &(to_string(&1.id) == to_string(id)))

  ## AI ------------------------------------------------------------------------

  # The page as the assistant sees it: the cards the current view shows (the
  # board's own cards, filtered as the mode filters them) and the open card.
  defp ai_source(mode, board, columns, config, card, users, can_write) do
    %{
      kind: :board,
      board: board,
      cards: ai_cards(mode, board, columns, config),
      # The board's wiki, so a request about documents is answered with
      # documents rather than with cards whose titles contain the word.
      pages: ai_pages(board, can_write),
      mode: mode,
      card: card,
      users: users
    }
  end

  # Drafts are only listed for someone who could have written them, exactly
  # as the wiki itself lists them.
  defp ai_pages(board, can_write) do
    Wiki.list_pages(board, if(can_write, do: [], else: [status: "published"]))
  end

  defp ai_cards(:board, _board, columns, _config), do: Enum.flat_map(columns, & &1.cards)

  defp ai_cards(_mode, board, _columns, config) do
    board.columns
    |> Enum.flat_map(& &1.cards)
    |> Enum.filter(&Swimlanes.matches?(&1, config))
  end

  ## PubSub ------------------------------------------------------------------

  defp drain_board_changed do
    receive do
      {:board_changed, _id} -> drain_board_changed()
    after
      0 -> :ok
    end
  end

  @impl true
  def handle_info({:board_changed, _id}, socket) do
    # A burst of writes (an import, an automation, a bulk move) queues one of
    # these per write; one reload answers all that have already arrived.
    drain_board_changed()
    socket = socket |> reload_board() |> refresh_swimlanes()
    board = socket.assigns.board

    socket =
      case socket.assigns do
        %{panel: :card, card: %Card{id: id}} ->
          case load_card(board, id) do
            {:ok, card} ->
              socket |> assign(card: card) |> assign_card_access()

            :error ->
              push_patch(socket, to: socket.assigns.paths.close)
          end

        %{panel: :activity} ->
          send_update(SlipdockWeb.BoardLive.ActivityComponent, id: "activity", refresh: true)
          socket

        %{panel: :archive} ->
          send_update(SlipdockWeb.BoardLive.ArchiveComponent, id: "archive", refresh: true)
          socket

        _ ->
          socket
      end

    {:noreply, socket}
  rescue
    Ecto.NoResultsError ->
      {:noreply,
       socket
       |> put_flash(:error, "This board was deleted.")
       |> push_navigate(to: ~p"/")}
  end

  # A callback finished: the panel's log, and the rule's own last run, move on.
  def handle_info({:callbacks_changed, _id}, %{assigns: %{panel: :automations}} = socket) do
    send_update(SlipdockWeb.BoardLive.AutomationsComponent, id: "automations", refresh: true)
    {:noreply, socket}
  end

  def handle_info({:rules_changed, rules}, socket), do: {:noreply, assign(socket, rules: rules)}

  # Who the board is shared with changed (see `BoardLive.SettingsComponent`).
  def handle_info(:refresh_assignable, socket), do: {:noreply, refresh_assignable(socket)}

  def handle_info({:moving_board, moving}, socket),
    do: {:noreply, assign(socket, moving_board: moving)}

  def handle_info({:sprint_picking, picking}, socket),
    do: {:noreply, assign(socket, sprint_picking: picking)}

  # A flash raised by one of the board's components (see `Helpers.flash/3`).
  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  # A component changed the board in a way the reader should see at once.
  def handle_info(:reload_board, socket), do: {:noreply, reload_board(socket)}

  def handle_info({:templates_changed}, socket) do
    {:noreply, assign(socket, templates: Boards.list_templates())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  ## Filters -----------------------------------------------------------------

  defp assign_columns(socket) do
    %{board: board, filters: filters} = socket.assigns

    columns =
      Enum.map(board.columns, fn col ->
        visible = Enum.filter(col.cards, &Slipdock.Filters.matches?(&1, filters))
        # A draft the reader couldn't have written was never theirs to see, so
        # it is not something the filters are hiding.
        readable = Enum.filter(col.pages, &page_visible?(&1, socket))
        pages = Enum.filter(readable, &Slipdock.Filters.matches?(&1, filters))

        %{
          column: col,
          cards: visible,
          pages: pages,
          # Cards and placed pages share one position sequence, so the list
          # is drawn from a single ordering rather than one after the other.
          items: interleave(visible, pages),
          hidden: length(col.cards) - length(visible) + (length(readable) - length(pages))
        }
      end)

    assign(socket, columns: columns, filtering: Slipdock.Filters.any?(filters))
  end

  defp interleave(cards, pages) do
    items =
      Enum.map(cards, &{&1.position, 0, {:card, &1}}) ++
        Enum.map(pages, &{&1.board_position, 1, {:page, &1}})

    items |> Enum.sort() |> Enum.map(&elem(&1, 2))
  end

  # A placed page carries the card facets, so it answers the same filters a
  # card does. The only question that is its own is whether the reader should
  # see it at all: a draft is for people who could have written it.
  defp page_visible?(page, socket), do: page.status != "draft" or socket.assigns.can_write

  defp put_filter(socket, key, value) do
    socket |> assign(filters: Map.put(socket.assigns.filters, key, value)) |> assign_columns()
  end

  ## Events: access guards ------------------------------------------------------

  @impl true
  def handle_event(event, _params, socket) when event not in @known_events do
    {:noreply, put_flash(socket, :error, "That isn't something this page can do.")}
  end

  def handle_event(event, _params, %{assigns: %{can_manage: false}} = socket)
      when event in @owner_events do
    {:noreply, put_flash(socket, :error, "Only the board's owner can do that.")}
  end

  def handle_event(event, _params, %{assigns: %{can_write: false}} = socket)
      when event in @board_write_events do
    {:noreply, put_flash(socket, :error, "You have read-only access to this board.")}
  end

  ## Events: sharing -------------------------------------------------------------

  def handle_event("share", %{"resource" => resource, "level" => _} = params, socket) do
    %{current_user: user, groups: groups} = socket.assigns

    with {:ok, target} <- share_target(socket, resource),
         {:ok, _} <- Sharing.share(target, params, groups, user) do
      {:noreply,
       socket
       |> update(:share_key, &(&1 + 1))
       |> refresh_grants(resource)
       |> refresh_assignable()}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("revoke_grant", %{"id" => id, "resource" => resource}, socket) do
    with {:ok, target} <- share_target(socket, resource),
         {:ok, _} <- Sharing.revoke(id, target) do
      {:noreply, socket |> refresh_grants(resource) |> refresh_assignable()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't remove that access.")}
    end
  end

  ## Events: filters ---------------------------------------------------------

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, put_filter(socket, :q, q)}

  def handle_event("filter_tag", %{"id" => id}, socket) do
    case Params.id(id) do
      nil ->
        {:noreply, socket}

      id ->
        tags = socket.assigns.filters.tags
        tags = if id in tags, do: List.delete(tags, id), else: [id | tags]
        {:noreply, put_filter(socket, :tags, tags)}
    end
  end

  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    kinds = socket.assigns.filters.kinds
    kinds = if kind in kinds, do: kinds -- [kind], else: [kind | kinds]
    {:noreply, put_filter(socket, :kinds, Enum.filter(Slipdock.Kinds.keys(), &(&1 in kinds)))}
  end

  def handle_event("filter_priority", %{"priority" => p}, socket) do
    {:noreply, put_filter(socket, :priority, toggle(socket.assigns.filters.priority, p))}
  end

  def handle_event("filter_flag", %{"flag" => f}, socket) do
    {:noreply, put_filter(socket, :flag, toggle(socket.assigns.filters.flag, f))}
  end

  def handle_event("filter_due", %{"due" => d}, socket) do
    {:noreply, put_filter(socket, :due, toggle(socket.assigns.filters.due, d))}
  end

  def handle_event("toggle_hide_completed", _, socket) do
    {:noreply, put_filter(socket, :hide_completed, !socket.assigns.filters.hide_completed)}
  end

  def handle_event("clear_filters", _, socket) do
    {:noreply, socket |> assign(filters: @empty_filters) |> assign_columns()}
  end

  ## Events: columns ---------------------------------------------------------

  def handle_event("start_add_column", _, socket),
    do: {:noreply, assign(socket, adding_column: true)}

  def handle_event("cancel_add_column", _, socket),
    do: {:noreply, assign(socket, adding_column: false)}

  def handle_event("add_column", %{"name" => name}, socket) do
    case Boards.create_column(socket.assigns.board, %{"name" => name}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(adding_column: false)
         |> push_event("scroll_end", %{})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "List name can't be blank.")}
    end
  end

  def handle_event("start_rename_column", %{"id" => id}, socket) do
    {:noreply, assign(socket, renaming_column: Params.id(id))}
  end

  def handle_event("cancel_rename_column", _, socket) do
    {:noreply, assign(socket, renaming_column: nil)}
  end

  def handle_event("rename_column", %{"column_id" => id, "name" => name}, socket) do
    with %Column{} = column <- board_column(socket, id),
         {:ok, _} <- Boards.update_column(column, %{"name" => name}) do
      {:noreply, assign(socket, renaming_column: nil)}
    else
      nil -> {:noreply, assign(socket, renaming_column: nil)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "List name can't be blank.")}
    end
  end

  def handle_event("move_column", %{"id" => id} = params, socket) do
    if id = Params.id(id),
      do: Boards.move_column(socket.assigns.board.id, id, to_int(params["before"]))

    {:noreply, socket}
  end

  ## Events: cards -----------------------------------------------------------

  def handle_event("start_add_card", %{"id" => id}, socket) do
    {:noreply, assign(socket, adding_to: Params.id(id))}
  end

  # The file picker is about to open: remember which list it was opened from,
  # because the upload that follows has no idea.
  def handle_event("aim_document", %{"id" => id}, socket) do
    {:noreply, assign(socket, document_column: column_id(id))}
  end

  def handle_event("cancel_add_card", _, socket), do: {:noreply, assign(socket, adding_to: nil)}

  # One line, Enter: the title with commands mixed in (see Slipdock.QuickAdd).
  # `group` (a table group key) sets what the group stands for, `column_id`
  # picks a list, `parent_card` adds a subcard beneath that card.
  def handle_event("quick_add_card", %{"title" => title} = params, socket) do
    %{board: board, swim: config} = socket.assigns
    form = params["form"]

    with {:ok, target, parent} <- quick_add_target(board, params["parent_card"]),
         {:ok, ops} <- quick_add_ops(config, params["group"]) do
      parsed = quick_parse(socket, title, target)

      column =
        parsed.column || quick_ops_column(target, ops) ||
          quick_param_column(target, params["column_id"]) || List.first(target.columns)

      cond do
        parsed.title == "" ->
          {:noreply, socket}

        is_nil(column) ->
          {:noreply, put_flash(socket, :error, "Add a list to the board first.")}

        true ->
          attrs = ops |> swim_attrs() |> Map.merge(parsed.attrs) |> Map.put("title", parsed.title)

          case Boards.create_card(column, attrs) do
            {:ok, card} ->
              tags = board_tags(board, swim_tag_ids(ops) || []) ++ parsed.tags
              if tags != [], do: Boards.set_card_tags(card, Enum.uniq_by(tags, & &1.id))
              if parent, do: Boards.broadcast_tree(Boards.root_of_board(board.id))

              {:noreply,
               socket
               |> update(:form_key, &(&1 + 1))
               |> update(:quick_preview, &Map.delete(&1, form))
               |> push_event("quick_added", %{form: form})}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Couldn't add that card.")}
          end
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Previews the commands recognised in a quick-add line as the user types.
  def handle_event("quick_add_change", %{"title" => title, "form" => form} = params, socket) do
    board = socket.assigns.board

    preview =
      with false <- String.trim(title) == "",
           {:ok, target, _} <- quick_add_target(board, params["parent_card"]),
           parsed <- quick_parse(socket, title, target),
           true <- Slipdock.QuickAdd.commands?(parsed) do
        parsed
      else
        _ -> nil
      end

    {:noreply,
     update(socket, :quick_preview, fn previews ->
       if preview, do: Map.put(previews, form, preview), else: Map.delete(previews, form)
     end)}
  end

  def handle_event("open_card", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: card_path(socket.assigns, id))}
  end

  # A list holds cards and, sometimes, wiki pages placed on the board. The
  # drag sends back whichever it moved — a bare number for a card, `page-7`
  # for a page — and both land in the same ordering.
  def handle_event("move_card", %{"id" => id, "to" => to} = params, socket) do
    case Boards.item_ref(id) do
      {:card, card_id} ->
        board = socket.assigns.board

        with {:ok, card} <- load_card(board, card_id),
             %Column{} = column <- board_column(socket, to) do
          Boards.move_card(card.id, column.id, params["before"])
        end

        {:noreply, socket}

      {:page, page_id} ->
        move_placed_page(socket, page_id, Params.id(to), params["before"])

      nil ->
        {:noreply, socket}
    end
  end

  # The tile's body opens the page's panel; its document icon is a link and
  # goes straight to the page (see `SlipdockWeb.SlipdockComponents.doc_link/1`).
  def handle_event("open_page", %{"id" => id}, socket),
    do: {:noreply, push_patch(socket, to: page_panel_path(socket, id))}

  ## Events: the keyboard's place on the board ---------------------------------
  #
  # One notion covers both keyboard moves and stepping through a list: the
  # focus is a list, a card in it, and whether that card is being carried.
  # "c" puts the focus on a list, "J" puts it on a card and picks it up, and
  # the arrows then either walk the focus or carry the card with it.

  def handle_event("focus_column", %{"id" => id}, %{assigns: %{mode: :board}} = socket) do
    case Enum.find(socket.assigns.columns, &(&1.column.id == to_int(id))) do
      %{column: column, cards: cards} ->
        {:noreply, put_focus(socket, column.id, card_id(List.first(cards)), false)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("focus_card", %{"id" => id} = params, %{assigns: %{mode: :board}} = socket) do
    %{columns: columns} = socket.assigns
    id = to_int(id)

    case id && locate_card(columns, id) do
      {ci, _index} ->
        %{column: column} = Enum.at(columns, ci)
        {:noreply, put_focus(socket, column.id, id, params["hold"] == true)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(event, _params, socket) when event in ~w(focus_column focus_card),
    do: {:noreply, socket}

  def handle_event("focus_hold", _params, socket) do
    case socket.assigns.focus do
      %{card_id: id} = focus when not is_nil(id) ->
        {:noreply, assign(socket, focus: %{focus | holding?: true})}

      _ ->
        {:noreply, socket}
    end
  end

  # "c" again, with the keyboard on a list: open that list's add-a-card row and
  # let go of the board, since the input takes the keyboard from here.
  def handle_event("focus_add", _params, socket) do
    case socket.assigns.focus do
      %{column_id: id} -> {:noreply, assign(socket, adding_to: id, focus: nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("focus_open", _params, socket) do
    case socket.assigns.focus do
      %{card_id: id} when not is_nil(id) ->
        {:noreply, push_patch(socket, to: card_path(socket.assigns, id))}

      _ ->
        {:noreply, socket}
    end
  end

  # Escape, and Enter on a card being carried: put the card down, or — when
  # the keyboard was only pointing at it — leave the board alone entirely.
  def handle_event("focus_end", _params, socket) do
    focus =
      case socket.assigns.focus do
        %{holding?: true} = focus -> %{focus | holding?: false}
        _ -> nil
      end

    {:noreply, assign(socket, focus: focus)}
  end

  # Each arrow moves a carried card for real, so the board the user is looking
  # at is always the board as it stands; a card only pointed at stays put and
  # the focus walks instead.
  def handle_event("focus_move", %{"dir" => dir}, socket)
      when dir in ~w(left right up down) do
    %{columns: columns, focus: focus} = socket.assigns
    {:noreply, assign(socket, focus: move_focus(columns, focus, dir))}
  end

  def handle_event("toggle_complete", %{"id" => id}, socket) do
    with {:ok, card} <- writable_card(socket, id) do
      Boards.toggle_completed(card)
      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  def handle_event("validate_document", _, socket),
    do: {:noreply, drop_invalid_uploads(socket, :list_document)}

  ## Events: swimlanes ---------------------------------------------------------

  def handle_event("swim_config", params, socket) do
    {:noreply, patch_swim(socket, Config.from_form(params, socket.assigns.swim))}
  end

  def handle_event("swim_set", %{"key" => key, "value" => value}, socket) do
    {:noreply, patch_swim(socket, Config.from_query(%{key => value}, socket.assigns.swim))}
  end

  def handle_event("swim_clear_filters", _, socket) do
    {:noreply, patch_swim(socket, Config.clear_filters(socket.assigns.swim))}
  end

  def handle_event("table_sort", %{"sort" => sort}, socket) do
    config = socket.assigns.swim

    config =
      if config.sort == sort,
        do: %{config | dir: if(config.dir == "asc", do: "desc", else: "asc")},
        else: %{config | sort: sort, dir: "asc"}

    {:noreply, patch_swim(socket, config)}
  end

  # The table's inline editors, which now set a placed wiki page's facets as
  # readily as a card's — the row sends `page-7` where a card sends a number.
  def handle_event("table_update", %{"card_id" => id, "field" => field, "value" => value}, socket)
      when field in ~w(priority start_date due_date percent_complete column_id) do
    case writable_item(socket, id) do
      {:ok, item} when item.board_id == socket.assigns.board.id ->
        case field do
          "column_id" ->
            if column_id = Params.id(value), do: move_in_list(item, column_id, nil)

          _ ->
            update_item(item, %{field => if(value == "", do: nil, else: value)})
        end

        {:noreply, reload_board(socket)}

      _ ->
        {:noreply, put_flash(socket, :error, "You have read-only access to that.")}
    end
  end

  ## Events: prioritise ------------------------------------------------------

  # A scoring field edited in place; `value` "" clears it.
  def handle_event(
        "prio_field",
        %{"card_id" => id, "field_id" => field_id, "value" => value},
        socket
      ) do
    %{board: board} = socket.assigns

    with {:ok, item} <- writable_item(socket, id),
         %FieldDefinition{} = field <-
           Enum.find(board.fields, &(to_string(&1.id) == to_string(field_id))),
         {:ok, _} <- Fields.set_value(item, field, value) do
      {:noreply, socket}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      nil -> {:noreply, put_flash(socket, :error, "That field no longer exists.")}
      _ -> {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  def handle_event("prio_vote", %{"card_id" => id, "count" => count}, socket) do
    %{current_user: user} = socket.assigns

    case readable_item(socket, id) do
      {:ok, item} ->
        with count when is_integer(count) <- Params.int(count),
             {:ok, _} <- Votes.set(item, user, count) do
          {:noreply, socket}
        else
          nil -> {:noreply, socket}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "You don't have access to that card.")}
    end
  end

  ## Events: timeline & calendar ---------------------------------------------

  # A bar was dragged: `edge` is "both", "start" or "end"; `delta` is in days.
  def handle_event("timeline_move", %{"id" => id, "edge" => edge, "delta" => delta}, socket)
      when edge in ~w(both start end) and is_integer(delta) do
    # Bars of subcards (nested rows) belong to boards deeper in the tree.
    with {:ok, card} <- writable_card(socket, id),
         true <- in_tree?(socket, card) do
      case Boards.update_card(card, Timeline.shift_attrs(card, edge, delta)) do
        {:ok, _} -> {:noreply, socket}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't move that card.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  # An unscheduled card was dropped on the timeline: `day` is the column index
  # into the current window, and becomes the card's due date.
  def handle_event("timeline_schedule", %{"id" => id, "day" => day}, socket)
      when is_integer(day) do
    %{from: from, days: days} = socket.assigns.timeline.window

    with true <- day >= 0 and day < days,
         {:ok, card} when card.board_id == socket.assigns.board.id <- writable_card(socket, id),
         {:ok, _} <-
           Boards.update_card(card, Slipdock.Calendar.move_attrs(card, Date.add(from, day))) do
      {:noreply, socket}
    else
      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Couldn't schedule that card.")}

      :error ->
        {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}

      _ ->
        {:noreply, socket}
    end
  end

  # A chip was dropped on a day (or back into the "no date" tray).
  def handle_event("cal_move", %{"id" => id, "to" => to}, socket) do
    with {:ok, item} when item.board_id == socket.assigns.board.id <- writable_item(socket, id),
         {:ok, attrs} <- cal_target(item, to, Slipdock.Calendar.place(socket.assigns.swim)),
         {:ok, _} <- update_item(item, attrs) do
      {:noreply, reload_board(socket)}
    else
      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Couldn't move that.")}

      :error ->
        {:noreply, put_flash(socket, :error, "You have read-only access to that.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cal_quick_add", %{"date" => date, "title" => title}, socket) do
    title = String.trim(title)

    with true <- title != "",
         {:ok, date} <- Date.from_iso8601(date),
         %Column{} = column <- List.first(socket.assigns.board.columns) do
      date_field =
        if Slipdock.Calendar.place(socket.assigns.swim) == "start",
          do: "start_date",
          else: "due_date"

      case Boards.create_card(column, %{"title" => title, date_field => date}) do
        {:ok, _} -> {:noreply, socket |> assign(swim_adding: nil) |> update(:form_key, &(&1 + 1))}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't add that card.")}
      end
    else
      nil -> {:noreply, put_flash(socket, :error, "Add a list to the board first.")}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cal_toggle_day", %{"key" => key}, socket) do
    expanded = socket.assigns.cal_expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, cal_expanded: expanded)}
  end

  def handle_event("swim_toggle_row", %{"key" => key}, socket) do
    collapsed = socket.assigns.swim_collapsed

    collapsed =
      if MapSet.member?(collapsed, key),
        do: MapSet.delete(collapsed, key),
        else: MapSet.put(collapsed, key)

    {:noreply, assign(socket, swim_collapsed: collapsed)}
  end

  def handle_event("swim_move", %{"id" => id, "from" => from, "to" => to} = params, socket) do
    %{swim: config, grid: grid} = socket.assigns

    with {:ok, {from_row, from_col}} <- cell_keys(grid, from),
         {:ok, {to_row, to_col}} <- cell_keys(grid, to),
         {:ok, item} <- load_item(socket.assigns.board, id) do
      ops =
        Swimlanes.move_ops(config.rows, item, from_row, to_row, config) ++
          Swimlanes.move_ops(config.cols, item, from_col, to_col, config)

      {:noreply, apply_swim_ops(socket, item, ops, params["before"])}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("swim_start_add", %{"cell" => cell}, socket) do
    {:noreply, assign(socket, swim_adding: cell)}
  end

  def handle_event("swim_cancel_add", _, socket), do: {:noreply, assign(socket, swim_adding: nil)}

  def handle_event("swim_quick_add", %{"cell" => cell, "title" => title}, socket) do
    %{swim: config, grid: grid, board: board} = socket.assigns
    title = String.trim(title)

    with true <- title != "",
         {:ok, {row_key, col_key}} <- cell_keys(grid, cell),
         %Column{} = column <- swim_add_column(board, config, row_key, col_key) do
      ops =
        Swimlanes.move_ops(config.rows, nil, nil, row_key, config) ++
          Swimlanes.move_ops(config.cols, nil, nil, col_key, config)

      attrs = Map.put(swim_attrs(ops), "title", title)

      case Boards.create_card(column, attrs) do
        {:ok, card} ->
          if tag_ids = swim_tag_ids(ops),
            do: Boards.set_card_tags(card, board_tags(board, tag_ids))

          {:noreply, update(socket, :form_key, &(&1 + 1))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Couldn't add that card.")}
      end
    else
      nil -> {:noreply, put_flash(socket, :error, "Add a list to the board first.")}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("swim_save_view", %{"name" => name}, socket) do
    %{board: board, swim: config} = socket.assigns

    config = %{config | mode: mode_name(socket)}

    case Boards.create_saved_view(board, %{"name" => name, "config" => Config.to_map(config)}) do
      {:ok, view} ->
        {:noreply,
         socket
         |> update(:form_key, &(&1 + 1))
         |> reload_board()
         |> push_patch(to: mode_path(socket.assigns, view: view.id))}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, view_error(cs))}
    end
  end

  def handle_event("swim_update_view", _, %{assigns: %{swim_view: %{} = view}} = socket) do
    config = %{socket.assigns.swim | mode: mode_name(socket)}
    {:ok, view} = Boards.update_saved_view(view, %{"config" => Config.to_map(config)})

    {:noreply,
     socket
     |> put_flash(:info, "View “#{view.name}” updated.")
     |> reload_board()
     |> push_patch(to: mode_path(socket.assigns, view: view.id))}
  end

  def handle_event(
        "swim_rename_view",
        %{"name" => name},
        %{assigns: %{swim_view: %{} = view}} = socket
      ) do
    case Boards.update_saved_view(view, %{"name" => name}) do
      {:ok, _} -> {:noreply, socket}
      {:error, cs} -> {:noreply, put_flash(socket, :error, view_error(cs))}
    end
  end

  def handle_event("swim_publish_view", _, %{assigns: %{swim_view: %{} = view}} = socket) do
    {:ok, _} = Boards.publish_saved_view(view)
    {:noreply, put_flash(socket, :info, "Published. Anyone with the link can read this view.")}
  end

  def handle_event("swim_unpublish_view", _, %{assigns: %{swim_view: %{} = view}} = socket) do
    {:ok, _} = Boards.unpublish_saved_view(view)
    {:noreply, put_flash(socket, :info, "The public link no longer works.")}
  end

  # Marking a view, a list or a card a favourite. Personal, so read access is
  # enough, and nothing about the board changes — only this reader's own set,
  # which `/favourites` lists and the view switcher draws from.
  def handle_event("toggle_favourite", %{"kind" => kind, "id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, kind} <- Favourites.kind(kind),
         id when is_integer(id) <- Params.id(id),
         {:ok, _} <- Favourites.toggle(user, kind, id) do
      {:noreply, assign(socket, favourites: Favourites.marks(user))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("swim_delete_view", _, %{assigns: %{swim_view: %{} = view}} = socket) do
    config = socket.assigns.swim
    {:ok, _} = Boards.delete_saved_view(view)
    defaults = Config.defaults(mode_name(socket))

    {:noreply,
     socket
     |> reload_board()
     |> push_patch(to: mode_path(socket.assigns, Config.to_query(config, defaults)))}
  end

  def handle_event(event, _, socket)
      when event in ~w(swim_update_view swim_rename_view swim_delete_view) do
    {:noreply, socket}
  end

  defp cal_target(_card, "none", _place), do: {:ok, %{"start_date" => nil, "due_date" => nil}}

  defp cal_target(card, iso, place) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> {:ok, Slipdock.Calendar.move_attrs(card, date, place)}
      _ -> :invalid
    end
  end

  # "row:col" cell ids from the grid -> the bucket keys on each axis.
  defp cell_keys(%{rows: rows, cols: cols}, cell) when is_binary(cell) do
    with [r, c] <- String.split(cell, ":"),
         {ri, ""} when ri >= 0 <- Integer.parse(r),
         {ci, ""} when ci >= 0 <- Integer.parse(c),
         %{key: row_key} <- Enum.at(rows, ri),
         %{key: col_key} <- Enum.at(cols, ci) do
      {:ok, {row_key, col_key}}
    else
      _ -> :error
    end
  end

  defp cell_keys(_, _), do: :error

  defp apply_swim_ops(socket, item, ops, before) do
    case Enum.find(ops, &match?({:error, _}, &1)) do
      {:error, message} ->
        put_flash(socket, :error, message)

      nil ->
        %{board: board, swim: config} = socket.assigns

        column_id =
          Enum.find_value(ops, fn
            {:column, id} -> id
            _ -> nil
          end)

        cond do
          # Dropping between two things is only meaningful in board order.
          config.sort == "position" ->
            move_in_list(item, column_id || item.column_id, before)

          column_id ->
            move_in_list(item, column_id, nil)

          true ->
            :ok
        end

        attrs = swim_attrs(ops)
        if attrs != %{}, do: update_item(item, attrs)
        if tag_ids = swim_tag_ids(ops), do: set_item_tags(item, board_tags(board, tag_ids))

        Enum.reduce(ops, socket, fn
          # Custom fields are a card's; a page has none, so dropping one on a
          # custom-field axis moves it and leaves the value alone rather than
          # inventing somewhere to put it.
          {:field, id, raw}, socket ->
            with false <- SlipdockWeb.SlipdockComponents.page?(item),
                 %{} = field <- Enum.find(board.fields, &(&1.id == id)) do
              case Fields.set_value(Boards.get_card!(item.id), field, raw) do
                {:ok, _} -> socket
                {:error, message} -> put_flash(socket, :error, message)
              end
            else
              _ -> socket
            end

          _, socket ->
            socket
        end)
    end
  end

  defp swim_attrs(ops) do
    Enum.reduce(ops, %{}, fn
      {:attrs, attrs}, acc -> Map.merge(acc, attrs)
      _, acc -> acc
    end)
  end

  defp swim_tag_ids(ops),
    do:
      Enum.find_value(ops, fn
        {:tags, ids} -> ids
        _ -> nil
      end)

  defp board_tags(board, ids), do: Enum.filter(board.tags, &(&1.id in ids))

  # The list a card added inside a cell should land in: the list on the
  # column/row axis if there is one, otherwise the first list on the board.
  defp swim_add_column(board, config, row_key, col_key) do
    key =
      cond do
        config.cols == "column" -> col_key
        config.rows == "column" -> row_key
        true -> nil
      end

    case key && Enum.find(board.columns, &(to_string(&1.id) == key)) do
      %Column{} = column -> column
      _ -> List.first(board.columns)
    end
  end

  # What may be shared from here, by whom: a saved view, by the board's owner.
  # (The board is shared from its settings panel, a card from its own.)
  defp share_target(%{assigns: %{can_manage: true, swim_view: %{} = view}}, "view"),
    do: {:ok, view}

  defp share_target(_, _), do: {:error, "You can't share that."}

  # The board's readers that this user can see. A page's current assignee is
  # added back where it is shown (`assignee_options/2`), so a facet form that
  # re-posts every field never unassigns somebody by leaving them out.
  defp assignable_users(board, user) do
    visible = user |> Access.visible_user_ids() |> MapSet.new()
    board |> Wiki.members() |> Enum.filter(&MapSet.member?(visible, &1.id))
  end

  defp refresh_assignable(socket) do
    %{board: board, current_user: user} = socket.assigns

    assign(socket,
      assignable: assignable_users(board, user),
      mention_people: SlipdockWeb.Mention.people(board)
    )
  end

  defp refresh_grants(socket, "view"),
    do: assign(socket, view_grants: Access.list_grants(socket.assigns.swim_view))

  # A card on this board (or one of its sub-boards) the user may edit.
  # Whether a card is on this board or any board beneath it.
  defp in_tree?(%{assigns: %{board: board}}, card),
    do: card.board_id == board.id or Slipdock.Rollup.member?(board.rollup, card)

  # A card on this board's tree the user may edit. Off the tree it is :error
  # whatever the user's rights to it: a view's grant covers the cards of this
  # board that match it, not every card on the server.
  defp writable_card(socket, id) do
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
  defp board_column(socket, id), do: Boards.get_board_column(socket.assigns.board.id, id)

  ## Keyboard focus ------------------------------------------------------------

  defp put_focus(socket, column_id, card_id, holding?) do
    assign(socket,
      focus: %{
        column_id: column_id,
        card_id: card_id,
        holding?: holding? and socket.assigns.can_write
      }
    )
  end

  defp move_focus(_columns, nil, _dir), do: nil

  # Carrying: the card moves and the focus goes with it.
  defp move_focus(columns, %{holding?: true, card_id: id} = focus, dir) when not is_nil(id) do
    case locate_card(columns, id) do
      {ci, index} ->
        nudge_card(columns, id, ci, index, dir)
        %{column: column} = Enum.at(columns, sidestep(ci, dir, length(columns)))
        %{focus | column_id: column.id}

      _ ->
        focus
    end
  end

  # Pointing: up and down walk the cards of the list, left and right step to
  # the list either side, keeping as close to the same place in it as it has.
  defp move_focus(columns, focus, dir) do
    case Enum.find_index(columns, &(&1.column.id == focus.column_id)) do
      nil ->
        nil

      ci ->
        index = card_index(Enum.at(columns, ci).cards, focus.card_id)
        ci = sidestep(ci, dir, length(columns))
        %{column: column, cards: cards} = Enum.at(columns, ci)

        index =
          case dir do
            "up" -> max(index - 1, 0)
            "down" -> index + 1
            _ -> index
          end

        index = min(index, max(length(cards) - 1, 0))
        %{focus | column_id: column.id, card_id: card_id(Enum.at(cards, index))}
    end
  end

  defp sidestep(ci, "left", _count), do: max(ci - 1, 0)
  defp sidestep(ci, "right", count), do: min(ci + 1, count - 1)
  defp sidestep(ci, _dir, _count), do: ci

  defp card_index(_cards, nil), do: 0
  defp card_index(cards, id), do: Enum.find_index(cards, &(&1.id == id)) || 0

  ## Keyboard card moves -------------------------------------------------------

  # Where a card sits on the board as the user sees it: the index of its list,
  # and its index among the cards that list is actually showing.
  defp locate_card(columns, id) do
    columns
    |> Enum.with_index()
    |> Enum.find_value(fn {%{cards: cards}, ci} ->
      case Enum.find_index(cards, &(&1.id == id)) do
        nil -> nil
        index -> {ci, index}
      end
    end)
  end

  # Left and right carry the card into the neighbouring list, keeping its place
  # in the order as closely as the shorter list allows; up and down shuffle it
  # one place within its own list. Both stop at the ends rather than wrapping.
  defp nudge_card(columns, id, ci, index, "left") when ci > 0,
    do: drop_into(columns, id, ci - 1, index)

  defp nudge_card(columns, id, ci, index, "right") when ci < length(columns) - 1,
    do: drop_into(columns, id, ci + 1, index)

  defp nudge_card(columns, id, ci, index, "up") when index > 0,
    do: reorder_within(columns, id, ci, index - 1)

  defp nudge_card(columns, id, ci, index, "down"),
    do: reorder_within(columns, id, ci, index + 1)

  defp nudge_card(_columns, _id, _ci, _index, _dir), do: :ok

  defp drop_into(columns, id, ci, index) do
    %{column: column, cards: cards} = Enum.at(columns, ci)
    Boards.move_card(id, column.id, before_id(cards, index))
  end

  # The card is already in this list, so it has to come out of the order before
  # the target index means what it looks like it means.
  defp reorder_within(columns, id, ci, index) do
    %{column: column, cards: cards} = Enum.at(columns, ci)
    Boards.move_card(id, column.id, before_id(Enum.reject(cards, &(&1.id == id)), index))
  end

  # The card the moved one lands in front of; nil parks it at the end.
  defp before_id(cards, index), do: card_id(Enum.at(cards, index))

  defp card_id(%Card{id: id}), do: id
  defp card_id(_), do: nil

  defp focus_title(_columns, nil), do: nil

  defp focus_title(columns, %{card_id: id}) do
    Enum.find_value(columns, fn %{cards: cards} ->
      Enum.find_value(cards, &(&1.id == id && &1.title))
    end)
  end

  # The views this board can switch to, for the "v" palette.
  defp assign_page_jumps(socket) do
    %{board: board, mode: mode, card_only: card_only, view_only: view_only} = socket.assigns

    jumps =
      if card_only or view_only do
        []
      else
        for {m, suffix, label, icon, _title, key} <- view_tabs_list() do
          %{
            key: key,
            label: label,
            icon: icon,
            patch: "/boards/#{board.id}#{suffix}",
            current: m == mode
          }
        end
      end

    assign(socket, page_jumps: jumps)
  end

  ## Render -------------------------------------------------------------------

  # The previous/next stepping a dated view's toolbar offers.
  defp view_nav(%{mode: :timeline, timeline: timeline}),
    do: Map.take(timeline, [:title, :prev, :next])

  defp view_nav(%{mode: :calendar, calendar: calendar}),
    do: Map.take(calendar, [:title, :prev, :next])

  defp view_nav(_assigns), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, focus_title: focus_title(assigns.columns, assigns.focus))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:boards}
      page_jumps={@page_jumps}
    >
      <:nav>
        <.board_nav
          board={@board}
          ancestry={@ancestry}
          paths={@paths}
          can_manage={@can_manage}
          can_write={@can_write}
        />
      </:nav>
      <:actions>
        <.board_actions
          board={@board}
          paths={@paths}
          can_manage={@can_manage}
          can_write={@can_write}
          card_only={@card_only}
          view_only={@view_only}
          sprint_of={@sprint_of}
          ai?={@ai?}
          rules={@rules}
        />
      </:actions>

      <%!-- Every view but the board's own: the same toolbar, then the view. --%>
      <div :if={@mode != :board and !@card_only} class="flex h-full flex-col">
        <.swim_toolbar
          mode={@mode}
          board={@board}
          config={@swim}
          view={@swim_view}
          dirty={@swim_dirty}
          grid={@grid}
          nav={view_nav(assigns)}
          form_key={@form_key}
          can_write={@can_write}
          can_manage={@can_manage}
          view_only={@view_only}
          allowed_views={@allowed_views}
          view_grants={@view_grants}
          groups={@groups}
          share_key={@share_key}
          favourites={@favourites}
        >
          <:leading>
            <.view_tabs
              :if={!@view_only}
              board={@board}
              mode={@mode}
              config={@swim}
              view={@swim_view}
              marks={@favourites}
            />
          </:leading>
        </.swim_toolbar>
        <div class="min-h-0 flex-1">
          <.table_view
            :if={@mode == :table}
            narrow={@narrow?}
            board={@board}
            config={@swim}
            rows={@table_rows}
            collapsed={@swim_collapsed}
            form_key={@form_key}
            can_write={@can_write}
            quick_preview={@quick_preview}
          />
          <.timeline_view
            :if={@mode == :timeline}
            narrow={@narrow?}
            board={@board}
            config={@swim}
            timeline={@timeline}
            collapsed={@swim_collapsed}
            form_key={@form_key}
            can_write={@can_write}
          />
          <.outline_view
            :if={@mode == :outline}
            board={@board}
            config={@swim}
            outline={@outline}
            collapsed={@swim_collapsed}
            can_write={@can_write}
            quick_preview={@quick_preview}
          />
          <.prioritise_view
            :if={@mode == :prioritise}
            narrow={@narrow?}
            board={@board}
            config={@swim}
            prioritise={@prioritise}
            can_write={@can_write}
            can_manage={@can_manage}
            current_user={@current_user}
          />
          <.narrative_view
            :if={@mode == :narrative}
            board={@board}
            config={@swim}
            narrative={@narrative}
            collapsed={@swim_collapsed}
            can_write={@can_write}
            view_name={@swim_view && @swim_view.name}
            ai={@ai?}
            current_user={@current_user}
          />
          <.calendar_view
            :if={@mode == :calendar}
            narrow={@narrow?}
            board={@board}
            config={@swim}
            calendar={@calendar}
            expanded={@cal_expanded}
            collapsed={@swim_collapsed}
            adding={@swim_adding}
            form_key={@form_key}
            can_write={@can_write}
          />
          <.swim_grid
            :if={@mode == :swimlanes}
            narrow={@narrow?}
            board={@board}
            grid={@grid}
            config={@swim}
            collapsed={@swim_collapsed}
            adding={@swim_adding}
            form_key={@form_key}
            can_write={@can_write}
          />
        </div>
      </div>

      <div
        :if={@card_only}
        class="flex h-full items-center justify-center p-8 text-center text-base-content/60"
      >
        <p>You have access to a single card on this board.</p>
      </div>

      <.kanban
        :if={@mode == :board and !@card_only}
        board={@board}
        columns={@columns}
        filters={@filters}
        filtering={@filtering}
        swim={@swim}
        swim_view={@swim_view}
        swim_dirty={@swim_dirty}
        form_key={@form_key}
        can_write={@can_write}
        can_manage={@can_manage}
        view_only={@view_only}
        view_grants={@view_grants}
        groups={@groups}
        share_key={@share_key}
        favourites={@favourites}
        narrow?={@narrow?}
        renaming_column={@renaming_column}
        focus={@focus}
        adding_to={@adding_to}
        adding_column={@adding_column}
        uploads={@uploads}
      />

      <div
        id="board-keys"
        phx-hook="BoardKeys"
        data-board={to_string(@mode == :board and !@card_only)}
        data-move={to_string(@mode == :board and @can_write and !@card_only)}
        data-focus={@focus && if(@focus.holding?, do: "hold", else: "point")}
        class="hidden"
      >
      </div>

      <.focus_toast :if={@focus} focus={@focus} focus_title={@focus_title} />

      <.live_component
        :if={@ai? and !@card_only}
        module={SlipdockWeb.AIChatComponent}
        id="page-ai"
        layout="drawer"
        title={"Chat about #{@board.name}"}
        source={ai_source(@mode, @board, @columns, @swim, @card, @users, @can_write)}
        current_user={@current_user}
        can_write={@can_write}
      />
      <%!-- The move picker stands in for the card while it is open: two
            full-screen modals on a phone is one too many, and the card's own
            click-away would fire on every tap inside the picker. Closing the
            picker brings the card back, because the panel never changed. --%>
      <%!-- A placed wiki page's panel: everything a card's sidebar sets, for
            a document. Opened by clicking the tile's body; the document
            itself is one click on the tile's icon. --%>
      <.live_component
        :if={@page_id}
        module={SlipdockWeb.BoardLive.PageComponent}
        id="page-panel"
        page_id={@page_id}
        board={@board}
        users={@assignable}
        current_user={@current_user}
        close_path={@paths.close}
      />
      <.live_component
        :if={@panel == :card and not is_nil(@card) and not @moving_board and not @sprint_picking}
        module={SlipdockWeb.BoardLive.CardComponent}
        id="card-panel"
        card={@card}
        board={@board}
        current_user={@current_user}
        swim={@swim}
        swim_view={@swim_view}
        mode={@mode}
        swim_query={@swim_query}
        users={@assignable}
        mention_people={@mention_people}
        close_path={@paths.close}
        tags_path={@paths.tags}
        templates={@templates}
        groups={@groups}
        favourites={@favourites}
        ai?={@ai?}
        parent={List.last(@ancestry)}
        close_navigate={@card_only}
      />
      <.live_component
        :if={@can_write}
        module={SlipdockWeb.BoardLive.ColumnComponent}
        id="column-settings"
        board={@board}
        current_user={@current_user}
      />
      <.live_component
        module={SlipdockWeb.BoardLive.MoveBoardComponent}
        id="move-board"
        current_user={@current_user}
        open_card_id={@panel == :card && @card && @card.id}
      />
      <.live_component
        module={SlipdockWeb.BoardLive.SprintComponent}
        id="sprints"
        board={@board}
        current_user={@current_user}
      />
      <.live_component
        :if={@panel == :tags}
        module={SlipdockWeb.BoardLive.TagsComponent}
        id="tags"
        board={@board}
        current_user={@current_user}
        close_path={@paths.close}
      />
      <.live_component
        :if={@panel == :activity}
        module={SlipdockWeb.BoardLive.ActivityComponent}
        id="activity"
        board={@board}
        current_user={@current_user}
        close_path={@paths.close}
      />
      <.live_component
        :if={@panel == :archive}
        module={SlipdockWeb.BoardLive.ArchiveComponent}
        id="archive"
        board={@board}
        current_user={@current_user}
        close_path={@paths.close}
      />
      <.live_component
        :if={@panel == :automations and @can_manage}
        module={SlipdockWeb.BoardLive.AutomationsComponent}
        id="automations"
        board={@board}
        current_user={@current_user}
        ai?={@ai?}
        close_path={@paths.close}
      />
      <.live_component
        :if={@panel == :settings and @can_manage}
        module={SlipdockWeb.BoardLive.SettingsComponent}
        id="settings"
        board={@board}
        current_user={@current_user}
        groups={@groups}
        close_path={@paths.close}
      />
    </Layouts.app>
    """
  end
end

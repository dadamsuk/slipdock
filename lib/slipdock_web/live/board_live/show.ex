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
  import SlipdockWeb.BoardLive.State

  alias Slipdock.{
    Access,
    Accounts,
    Automations,
    Boards,
    Favourites,
    Sprints,
    Swimlanes,
    Wiki
  }

  alias Slipdock.Boards.{
    Attachment,
    Card,
    Column
  }

  alias SlipdockWeb.Params
  alias SlipdockWeb.BoardLive.{Keyboard, Sharing, ViewEvents}
  alias Slipdock.Swimlanes.Config

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

  # Handled by `BoardLive.ViewEvents` and `BoardLive.Keyboard`, once the
  # guards have let them through.
  @view_events ViewEvents.events()
  @keyboard_events Keyboard.events()

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

  ## Swimlane configuration ---------------------------------------------------

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

  # The other views' events and the keyboard's live in modules of their own;
  # they get here only past the guards above.
  def handle_event(event, params, socket) when event in @view_events,
    do: ViewEvents.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @keyboard_events,
    do: Keyboard.handle_event(event, params, socket)

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

  # What may be shared from here, by whom: a saved view, by the board's owner.
  # (The board is shared from its settings panel, a card from its own.)
  defp share_target(%{assigns: %{can_manage: true, swim_view: %{} = view}}, "view"),
    do: {:ok, view}

  defp share_target(_, _), do: {:error, "You can't share that."}

  defp refresh_grants(socket, "view"),
    do: assign(socket, view_grants: Access.list_grants(socket.assigns.swim_view))

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
    assigns = assign(assigns, focus_title: Keyboard.focus_title(assigns.columns, assigns.focus))

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

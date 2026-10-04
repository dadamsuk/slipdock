defmodule SlipdockWeb.BoardLive.Show do
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ItemComponents
  import SlipdockWeb.SwimlaneComponents
  import SlipdockWeb.TableComponents
  import SlipdockWeb.TimelineComponents
  import SlipdockWeb.CalendarComponents
  import SlipdockWeb.OutlineComponents
  import SlipdockWeb.NarrativeComponents
  import SlipdockWeb.PrioritiseComponents
  import SlipdockWeb.ShareComponents
  import SlipdockWeb.BoardLive.Paths
  import SlipdockWeb.BoardLive.Helpers

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

  alias Slipdock.Boards.Owned

  alias Slipdock.Boards.{
    Attachment,
    Board,
    Card,
    CardLink,
    Column,
    FieldDefinition
  }

  alias SlipdockWeb.{Params, RichText}
  alias SlipdockWeb.BoardLive.Sharing
  alias Slipdock.Dates
  alias Slipdock.Palette
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
  @board_write_events ~w(add_column rename_column move_column quick_add_card move_card unplace_page place_page
    focus_move focus_hold focus_add swim_move swim_quick_add cal_quick_add swim_save_view
    swim_update_view swim_rename_view swim_delete_view restore_card delete_archived)
  # Events that change the open card; refused with read-only access to it.
  @card_write_events ~w(card_change toggle_flag toggle_tag set_cover archive_card delete_card
    add_dependency remove_dependency create_sub_board remove_assignee
    delete_sub_board quick_add_subcard toggle_subcard edit_description validate_attachments
    cancel_upload delete_attachment add_link remove_link
    write_up toggle_pin_doc doc_search attach_doc detach_doc)
  # Events that change the *contents* of whichever panel is open — a card's
  # or a placed page's. Guarded by that thing's own permission.
  @item_write_events ~w(add_check toggle_check delete_check add_comment delete_comment comment_change
    add_status_update delete_status_update add_card_url remove_card_url set_field vote)
  # Events whose handler checks the permission itself, because what it acts
  # on is not the open board or the open card: a card named by id, a page,
  # another board, a sprint picked from several boards.
  @self_checked_events ~w(share revoke_grant page_change page_toggle_flag page_toggle_tag
    toggle_complete card_timer
    log_time table_update prio_field prio_vote timeline_move timeline_schedule cal_move
    toggle_favourite)
  # Events that change nothing stored: filters, panels opening and closing,
  # forms being typed into, the keyboard's place on the board.
  @read_events ~w(search filter_tag filter_kind filter_priority filter_flag filter_due
    toggle_hide_completed clear_filters start_add_column cancel_add_column
    start_rename_column cancel_rename_column start_add_card aim_document cancel_add_card
    quick_add_change open_card open_page close_page focus_column focus_card focus_open
    focus_end stop_editing_description validate_document dep_direction dep_search
    link_search pick_template swim_config swim_set swim_clear_filters table_sort
    cal_toggle_day swim_toggle_row swim_start_add swim_cancel_add)

  # Images pasted into the description or a comment, and files attached explicitly.
  @image_uploads [:desc_image, :comment_image]
  @uploads [:attachment | @image_uploads]

  @image_accept ~w(.png .jpg .jpeg .gif .webp image/png image/jpeg image/gif image/webp)
  # Events only the board owner may perform.
  @owner_events ~w(swim_publish_view swim_unpublish_view)

  @known_events @owner_events ++
                  @board_write_events ++
                  @card_write_events ++
                  @item_write_events ++ @self_checked_events ++ @read_events

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
         card_perm: :none,
         card_can_write: false,
         item_can_write: false,
         card_pages: [],
         # The picker for attaching a page somebody has already written,
         # beside "Write it up" which starts a new one.
         doc_query: "",
         doc_results: [],
         open_page: nil,
         page_form: nil,
         page_can_write: false,
         card_grants: [],
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
      card_form: nil,
      activities: [],
      archived: [],
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
      dep_direction: "blocked_by",
      dep_query: "",
      dep_results: [],
      link_kind: "relates",
      link_query: "",
      link_results: [],
      ancestry: Boards.ancestry(board),
      templates: Boards.list_templates(),
      users: Access.visible_users(socket.assigns.current_user),
      # Who the card and page pickers offer: only people who could be put on
      # one (see `Boards.resolve_assignees/3`), not everybody in the directory.
      assignable: assignable_users(board, socket.assigns.current_user),
      picking_template: false,
      editing_description: false,
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

  defp allow_uploads(socket) do
    opts = [auto_upload: true, progress: &handle_upload/3]

    socket
    |> allow_upload(
      :attachment,
      [accept: :any, max_entries: 10, max_file_size: Attachment.max_size()] ++ opts
    )
    |> allow_upload(
      :desc_image,
      [accept: @image_accept, max_entries: 5, max_file_size: 10_000_000] ++ opts
    )
    |> allow_upload(
      :comment_image,
      [accept: @image_accept, max_entries: 5, max_file_size: 10_000_000] ++ opts
    )
    # A file dropped at the foot of a list: a card of its own, named after
    # the file, with the file attached.
    |> allow_upload(
      :list_document,
      [accept: :any, max_entries: 5, max_file_size: Attachment.max_size()] ++ opts
    )
  end

  # An in-flight upload belongs to the card that was open when it started.
  defp cancel_all_uploads(socket) do
    Enum.reduce(@uploads, socket, fn name, socket ->
      Enum.reduce(socket.assigns.uploads[name].entries, socket, &cancel_upload(&2, name, &1.ref))
    end)
  end

  # Invalid entries (too big, wrong type) are dropped straight away and
  # reported once, instead of lingering in the upload list.
  defp drop_invalid_uploads(socket, name) do
    upload = socket.assigns.uploads[name]

    Enum.reduce(upload.entries, socket, fn entry, socket ->
      case upload_errors(upload, entry) do
        [] ->
          socket

        [err | _] ->
          socket
          |> cancel_upload(name, entry.ref)
          |> put_flash(:error, "#{entry.client_name} #{upload_error(err)}.")
          |> then(fn socket ->
            if name in @image_uploads,
              do: push_event(socket, "image_failed", %{upload: Atom.to_string(name)}),
              else: socket
          end)
      end
    end)
  end

  defp upload_error(:too_large), do: "is too large"
  defp upload_error(:not_accepted), do: "isn't an image (PNG, JPEG, GIF or WebP)"
  defp upload_error(:too_many_files), do: "couldn't be added: too many files at once"
  defp upload_error(:external_client_failure), do: "failed to upload"
  defp upload_error(other), do: "couldn't be uploaded (#{other})"

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

  defp handle_upload(name, entry, socket) do
    card = socket.assigns.card

    cond do
      not entry.done? ->
        {:noreply, socket}

      is_nil(card) or not socket.assigns.card_can_write ->
        {:noreply, cancel_upload(socket, name, entry.ref)}

      true ->
        meta = %{
          filename: entry.client_name,
          content_type: entry.client_type,
          size: entry.client_size
        }

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, Boards.add_attachment(card, meta, path)}
          end)

        {:noreply, uploaded(socket, name, result)}
    end
  end

  # A file's name is a fair card title; the extension is not part of it.
  defp document_title(entry) do
    case entry.client_name |> Path.basename() |> Path.rootname() |> String.trim() do
      "" -> entry.client_name
      title -> String.slice(title, 0, 200)
    end
  end

  defp uploaded(socket, :attachment, {:ok, _}), do: socket

  defp uploaded(socket, name, {:ok, attachment}) do
    push_event(socket, "image_uploaded", %{
      upload: Atom.to_string(name),
      markdown: "![#{attachment.filename}](#{Boards.attachment_url(attachment)})"
    })
  end

  defp uploaded(socket, name, {:error, changeset}) do
    {field, {msg, _}} = List.first(changeset.errors) || {:file, {"could not be stored", []}}

    socket
    |> put_flash(:error, "Upload failed: #{field} #{msg}.")
    |> then(fn socket ->
      if name in @image_uploads,
        do: push_event(socket, "image_failed", %{upload: Atom.to_string(name)}),
        else: socket
    end)
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

  defp assign_card_access(%{assigns: %{card: %Card{} = card}} = socket) do
    %{current_user: user, view_only: view_only, swim: config, swim_view: view} = socket.assigns

    {readable, writable} =
      if view_only do
        matches = Swimlanes.matches?(card, config)
        level = if view, do: Access.view_permission(user, view), else: :none
        {matches, matches and Access.can_write?(level)}
      else
        perm = Access.card_permission(user, card)
        {Access.can_read?(perm), Access.can_write?(perm)}
      end

    if readable do
      assign(socket,
        card_perm: if(writable, do: :write, else: :read),
        card_can_write: writable,
        card_grants:
          if(socket.assigns.can_manage or writable, do: Access.list_grants(card), else: []),
        # The wiki pages that talk about this card, pinned first (see
        # `Slipdock.Wiki.Links`). This is the half of the integration that means
        # nobody has to remember the wiki exists.
        card_pages: Wiki.pages_for_card(card, user)
      )
    else
      socket
      |> assign(
        card: nil,
        card_form: nil,
        card_perm: :none,
        card_can_write: false,
        card_grants: [],
        card_pages: []
      )
      |> put_flash(:error, "You don't have access to that card.")
      |> push_patch(to: socket.assigns.paths.close)
    end
  end

  defp assign_card_access(socket),
    do: assign(socket, card_perm: :none, card_can_write: false, card_grants: [], card_pages: [])

  # Pages on this board's tree that are not already on the card. Titles and
  # summaries only: finding the page you mean is a different job from
  # searching its prose, which `/search` does by meaning.
  defp assign_doc_results(socket) do
    query = String.trim(socket.assigns.doc_query || "")
    attached = MapSet.new(socket.assigns.card_pages, & &1.page.id)

    results =
      if query == "" do
        []
      else
        socket.assigns.board
        |> Wiki.list_pages(q: query, template: false, archived: false)
        |> Enum.reject(&MapSet.member?(attached, &1.id))
        |> Enum.take(8)
      end

    assign(socket, doc_results: results)
  end

  ## The panel for a placed wiki page -----------------------------------------

  defp assign_open_page(socket, nil),
    do: socket |> assign(open_page: nil, page_form: nil) |> assign_item_access()

  defp assign_open_page(socket, id) do
    case load_placed_page(socket.assigns.board, id) do
      {:ok, page} ->
        socket
        |> assign(
          open_page: page,
          page_form: to_form(Wiki.change_page(page, %{})),
          page_can_write:
            Access.can_write?(Access.page_permission(socket.assigns.current_user, page))
        )
        |> assign_item_access()

      _ ->
        socket |> assign(open_page: nil, page_form: nil) |> assign_item_access()
    end
  end

  # The thing the panel's *contents* events act on: the open page when a page
  # panel is up, the open card otherwise. The sections in
  # `SlipdockWeb.ItemComponents` draw either, so the handlers behind them take
  # either too, and there is one set of them rather than two.
  defp subject(%{assigns: %{open_page: %Slipdock.Wiki.Page{} = page}}), do: page
  defp subject(socket), do: socket.assigns.card

  defp item_ref_of(%Slipdock.Wiki.Page{id: id}), do: {:page, id}
  defp item_ref_of(%Card{id: id}), do: {:card, id}
  defp item_ref_of(nil), do: nil

  # Put the changed subject back in front of the reader.
  defp reload_subject(socket) do
    case subject(socket) do
      %Slipdock.Wiki.Page{} -> refresh_open_page(socket)
      %Card{id: id} -> assign(socket, card: Boards.get_card!(id))
      nil -> socket
    end
  end

  # Whether the reader may write to whichever of the two is open. Kept as an
  # assign because the write guard is a pattern match on the socket.
  defp assign_item_access(socket) do
    assign(socket,
      item_can_write:
        if(socket.assigns[:open_page],
          do: socket.assigns[:page_can_write] == true,
          else: socket.assigns.card_can_write
        )
    )
  end

  defp refresh_open_page(socket) do
    case socket.assigns.open_page do
      %Slipdock.Wiki.Page{id: id} -> assign_open_page(socket, to_string(id))
      _ -> socket
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
      |> assign_open_page(params["page"])

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
    do: socket |> cancel_all_uploads() |> assign(card: nil, card_form: nil)

  defp apply_panel(socket, :card, %{"card_id" => card_id}) do
    case load_card(socket.assigns.board, card_id) do
      {:ok, card} ->
        same_card = match?(%Card{id: id} when id == card.id, socket.assigns.card)

        socket
        |> then(&if(same_card, do: &1, else: cancel_all_uploads(&1)))
        |> assign(
          card: card,
          card_form: to_form(Boards.change_card(card)),
          dep_query: "",
          dep_results: [],
          link_query: "",
          link_results: [],
          picking_template: false,
          editing_description: same_card and socket.assigns.editing_description
        )
        |> assign_card_access()

      :error ->
        socket
        |> put_flash(:error, "That card no longer exists.")
        |> push_patch(to: socket.assigns.paths.close)
    end
  end

  defp apply_panel(socket, :activity, _) do
    assign(socket, activities: Boards.list_activities(socket.assigns.board.id))
  end

  defp apply_panel(socket, :archive, _) do
    assign(socket, archived: Boards.list_archived_cards(socket.assigns.board.id))
  end

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

  defp load_card(board, card_id) do
    card = Boards.get_card!(card_id)
    if card.board_id == board.id and is_nil(card.archived_at), do: {:ok, card}, else: :error
  rescue
    Ecto.NoResultsError -> :error
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

  defp load_placed_page(board, page_id) do
    case Wiki.find_page(page_id) do
      {:ok, %Slipdock.Wiki.Page{board_id: board_id, archived_at: nil} = page}
      when board_id == board.id ->
        {:ok, Slipdock.Wiki.Page.for_board(Slipdock.Repo.preload(page, Wiki.board_preloads()))}

      _ ->
        :error
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

  # The ids a form posts are the browser's to choose, so whoever they name
  # goes through the same gate as the API (`Boards.resolve_assignees/3`):
  # somebody this user can see, who can open `target`.
  defp scope_assignees(params, target, user) do
    Enum.reduce_while(~w(assignee_id add_assignee_ids), {:ok, params}, fn key, {:ok, acc} ->
      refs = acc |> Map.get(key) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

      case refs != [] && Boards.resolve_assignees(target, user, refs) do
        false -> {:cont, {:ok, acc}}
        {:ok, ids} when key == "assignee_id" -> {:cont, {:ok, Map.put(acc, key, hd(ids))}}
        {:ok, ids} -> {:cont, {:ok, Map.put(acc, key, ids)}}
        {:error, _} -> {:halt, :error}
      end
    end)
  end

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
              # Keep the form's current changeset params, only refresh the data.
              socket
              |> assign(card: card, card_form: to_form(Boards.change_card(card)))
              |> assign_card_access()

            :error ->
              push_patch(socket, to: socket.assigns.paths.close)
          end

        %{panel: :activity} ->
          assign(socket, activities: Boards.list_activities(board.id))

        %{panel: :archive} ->
          assign(socket, archived: Boards.list_archived_cards(board.id))

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

  def handle_event(event, _params, %{assigns: %{card_can_write: false}} = socket)
      when event in @card_write_events do
    {:noreply, put_flash(socket, :error, "You have read-only access to this card.")}
  end

  def handle_event(event, _params, %{assigns: %{item_can_write: false}} = socket)
      when event in @item_write_events do
    {:noreply, put_flash(socket, :error, "You have read-only access to this.")}
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

  def handle_event("close_page", _params, socket),
    do: {:noreply, push_patch(socket, to: socket.assigns.paths.close)}

  # The facets, changed from the panel. Everything a card's sidebar sets, a
  # page's sets the same way.
  def handle_event("page_change", %{"page" => params}, socket) do
    with %Slipdock.Wiki.Page{} = page <- socket.assigns.open_page,
         true <- socket.assigns.page_can_write do
      attrs =
        params
        |> Map.take(~w(title summary priority start_date due_date date_precision completed
                       percent_complete color assignee_id status))
        |> Map.new(fn
          {k, ""} when k in ~w(start_date due_date percent_complete assignee_id color) -> {k, nil}
          pair -> pair
        end)

      with {:ok, attrs} <- scope_assignees(attrs, page, socket.assigns.current_user),
           {:ok, _} <-
             Wiki.update_page(Wiki.get_page!(page.id), attrs,
               user: socket.assigns.current_user,
               via: "web"
             ) do
        {:noreply, reload_board(socket) |> refresh_open_page()}
      else
        :error ->
          {:noreply, put_flash(socket, :error, "That person can't be put on this page.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          # A rejected facet has to say so: silently keeping the old value is
          # how you spend a minute wondering why the select will not stick.
          {:noreply,
           socket
           |> assign(page_form: to_form(changeset, action: :validate))
           |> put_flash(:error, changeset_message(changeset))}

        _ ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "You have read-only access to that page.")}
    end
  end

  def handle_event("page_toggle_flag", %{"flag" => flag}, socket) do
    with %Slipdock.Wiki.Page{} = page <- socket.assigns.open_page,
         true <- socket.assigns.page_can_write do
      flags =
        if flag in page.flags, do: List.delete(page.flags, flag), else: page.flags ++ [flag]

      {:ok, _} =
        Wiki.update_page(Wiki.get_page!(page.id), %{"flags" => flags},
          user: socket.assigns.current_user,
          via: "web"
        )

      {:noreply, reload_board(socket) |> refresh_open_page()}
    else
      _ -> {:noreply, put_flash(socket, :error, "You have read-only access to that page.")}
    end
  end

  def handle_event("page_toggle_tag", %{"id" => tag_id}, socket) do
    with %Slipdock.Wiki.Page{} = page <- socket.assigns.open_page,
         true <- socket.assigns.page_can_write,
         %{} = tag <- Enum.find(socket.assigns.board.tags, &(to_string(&1.id) == tag_id)) do
      current = Wiki.tags(page)

      tags =
        if Enum.any?(current, &(&1.id == tag.id)),
          do: Enum.reject(current, &(&1.id == tag.id)),
          else: current ++ [tag]

      {:ok, _} = Wiki.set_tags(page, tags)
      {:noreply, reload_board(socket) |> refresh_open_page()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("unplace_page", %{"id" => id}, socket) do
    with {:ok, page} <- Wiki.find_page(id),
         true <- Access.can_write?(Access.page_permission(socket.assigns.current_user, page)),
         {:ok, _} <- Wiki.unplace(page) do
      {:noreply,
       socket
       |> put_flash(:info, "Took “#{page.title}” off the board. It is still in the wiki.")
       |> reload_board()}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be taken off the board.")}
    end
  end

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

  def handle_event("card_change", %{"card" => params} = event, socket) do
    card = socket.assigns.card
    socket = drop_invalid_uploads(socket, :desc_image)

    params =
      params
      |> Map.take(
        ~w(title description priority start_date due_date date_precision completed percent_complete column_id assignee_id add_assignee_id)
      )
      # The time form posts all three together, but spent and estimate are
      # typed in the unit on screen: re-sending them alongside a new unit would
      # read them in it. Only the field that changed goes through.
      |> Map.merge(Map.take(params, time_target(event)))
      |> Map.new(fn
        # Only the fields the changed form carries are touched: the title/description
        # form and the sidebar form both post here.
        {"start_date", ""} -> {"start_date", nil}
        {"due_date", ""} -> {"due_date", nil}
        {"percent_complete", ""} -> {"percent_complete", nil}
        {"assignee_id", ""} -> {"assignee_id", nil}
        # "Add someone" puts a person on the card beside whoever is there.
        {"add_assignee_id", id} -> {"add_assignee_ids", [id]}
        {"description", text} -> {"description", strip_upload_placeholder(text)}
        pair -> pair
      end)

    with {:ok, params} <- scope_assignees(params, card, socket.assigns.current_user) do
      with %{"column_id" => col} when col != "" <- params,
           new_col when is_integer(new_col) and new_col != card.column_id <- Params.id(col) do
        Boards.move_card(card.id, new_col, nil)
      end

      card = Boards.get_card!(card.id)

      case Boards.update_card(card, Map.delete(params, "column_id"),
             by: socket.assigns.current_user
           ) do
        {:ok, card} ->
          {:noreply, assign(socket, card: Boards.get_card!(card.id))}

        {:error, cs} ->
          {:noreply, assign(socket, card_form: to_form(cs))}
      end
    else
      :error -> {:noreply, put_flash(socket, :error, "That person can't be put on this card.")}
    end
  end

  def handle_event("card_timer", %{"action" => action}, socket) do
    with {:ok, card} <- writable_card(socket, socket.assigns.card.id),
         {:ok, _} <-
           if(action == "stop", do: Boards.stop_timer(card), else: Boards.start_timer(card)) do
      {:noreply, assign(socket, card: Boards.get_card!(card.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  def handle_event("log_time", %{"amount" => amount}, socket) do
    with {:ok, card} <- writable_card(socket, socket.assigns.card.id) do
      case Boards.update_card(card, %{"log_time" => amount}, by: socket.assigns.current_user) do
        {:ok, card} ->
          {:noreply,
           socket
           |> assign(card: Boards.get_card!(card.id))
           |> update(:form_key, &(&1 + 1))}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "Couldn't read “#{amount}” as a time — try 45m, 1.5h or 2d.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  # "Write it up": a page for this card, pinned to it, from a template when
  # the board has one. It opens in the editor rather than being left to find.
  def handle_event("write_up", _params, socket) do
    card = socket.assigns.card

    case Wiki.create_page_from_card(card, user: socket.assigns.current_user, via: "web") do
      {:ok, page} ->
        {:noreply,
         socket
         |> put_flash(:info, "Started #{page.code} for “#{card.title}”.")
         |> push_navigate(to: ~p"/boards/#{page.board_id}/wiki/#{page.slug}/edit")}

      _ ->
        {:noreply, put_flash(socket, :error, "That page couldn't be started.")}
    end
  end

  # Attaching a page that already exists. "Write it up" is for the document
  # that does not exist yet; most of the time the writing is already there
  # and what is missing is the link to it.
  def handle_event("doc_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(doc_query: q) |> assign_doc_results()}
  end

  def handle_event("attach_doc", %{"page" => page_id}, socket) do
    card = socket.assigns.card

    with {:ok, page} <- readable_page(socket, page_id),
         {:ok, _} <- Wiki.pin(page, {:card, card}) do
      {:noreply,
       socket
       |> put_flash(:info, "Attached #{page.code} to this card.")
       |> assign(doc_query: "", doc_results: [])
       |> assign_card_access()}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be attached.")}
    end
  end

  def handle_event("detach_doc", %{"page" => page_id}, socket) do
    card = socket.assigns.card

    with {:ok, page} <- Wiki.find_page(page_id),
         {:ok, _} <- Wiki.unlink(page, {:card, card}) do
      {:noreply, assign_card_access(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be detached.")}
    end
  end

  def handle_event("toggle_pin_doc", %{"page" => page_id}, socket) do
    card = socket.assigns.card

    with {:ok, page} <- readable_page(socket, page_id),
         link <- Enum.find(socket.assigns.card_pages, &(&1.page.id == page.id)),
         {:ok, _} <- Wiki.pin(page, {:card, card}, not (link && link.pinned)) do
      {:noreply, assign_card_access(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That page couldn't be pinned.")}
    end
  end

  def handle_event("remove_assignee", %{"id" => id}, socket) do
    {:ok, _} = Boards.update_card(socket.assigns.card, %{"remove_assignee_ids" => [id]})
    {:noreply, socket}
  end

  def handle_event("toggle_flag", %{"flag" => flag}, socket) do
    {:ok, _} = Boards.toggle_flag(socket.assigns.card, flag)
    {:noreply, socket}
  end

  def handle_event("toggle_tag", %{"id" => id}, socket) do
    if tag = board_tag(socket, id),
      do: {:ok, _} = Boards.toggle_card_tag(socket.assigns.card, tag)

    {:noreply, socket}
  end

  def handle_event("set_cover", %{"color" => color}, socket) do
    {:ok, _} = Boards.update_card(socket.assigns.card, %{"color" => color})
    {:noreply, socket}
  end

  def handle_event("archive_card", _, socket) do
    {:ok, _} = Boards.archive_card(socket.assigns.card)
    {:noreply, push_patch(socket, to: socket.assigns.paths.close)}
  end

  def handle_event("delete_card", _, socket) do
    {:ok, _} = Boards.delete_card(socket.assigns.card)
    {:noreply, push_patch(socket, to: socket.assigns.paths.close)}
  end

  def handle_event("restore_card", %{"id" => id}, socket) do
    case Boards.get_archived_card(socket.assigns.board.id, id) do
      nil ->
        {:noreply, socket}

      card ->
        case Boards.unarchive_card(card) do
          {:ok, _} ->
            {:noreply, socket}

          {:error, refused} ->
            {:noreply, put_flash(socket, :error, Slipdock.Quota.refusal_message(refused))}
        end
    end
  end

  def handle_event("delete_archived", %{"id" => id}, socket) do
    if card = Boards.get_archived_card(socket.assigns.board.id, id),
      do: {:ok, _} = Boards.delete_card(card)

    {:noreply, socket}
  end

  ## Events: checklist & comments -------------------------------------------

  def handle_event("add_check", %{"text" => text}, socket) do
    if String.trim(text) != "" do
      {:ok, _} = Boards.add_checklist_item(subject(socket), String.trim(text))
    end

    {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload_subject()}
  end

  def handle_event("toggle_check", %{"id" => id}, socket) do
    if item = Boards.get_checklist_item(subject(socket), id),
      do: Boards.toggle_checklist_item(item)

    {:noreply, reload_subject(socket)}
  end

  def handle_event("delete_check", %{"id" => id}, socket) do
    if item = Boards.get_checklist_item(subject(socket), id),
      do: Boards.delete_checklist_item(item)

    {:noreply, reload_subject(socket)}
  end

  def handle_event("add_status_update", %{"health" => health} = params, socket) do
    user = socket.assigns.current_user
    subject = subject(socket)

    case Boards.add_status_update(subject, user, %{"health" => health, "body" => params["body"]}) do
      {:ok, _} ->
        {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload_subject()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Pick a health to report.")}
    end
  end

  def handle_event("delete_status_update", %{"id" => id}, socket) do
    if Enum.any?(subject(socket).status_updates, &(to_string(&1.id) == to_string(id))) do
      {:ok, _} = Boards.delete_status_update(Params.id(id))
      {:noreply, reload_subject(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_comment", %{"body" => body}, socket) do
    body = body |> strip_upload_placeholder() |> String.trim()

    if body != "" do
      {:ok, _} = Boards.add_comment(subject(socket), body, by: socket.assigns.current_user)
    end

    {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload_subject()}
  end

  def handle_event("comment_change", _, socket),
    do: {:noreply, drop_invalid_uploads(socket, :comment_image)}

  ## Events: description & attachments ----------------------------------------

  def handle_event("edit_description", _, socket),
    do: {:noreply, assign(socket, editing_description: true)}

  def handle_event("stop_editing_description", _, socket),
    do: {:noreply, assign(socket, editing_description: false)}

  def handle_event("validate_attachments", _, socket),
    do: {:noreply, drop_invalid_uploads(socket, :attachment)}

  def handle_event("validate_document", _, socket),
    do: {:noreply, drop_invalid_uploads(socket, :list_document)}

  def handle_event("cancel_upload", %{"name" => name, "ref" => ref}, socket)
      when name in ~w(attachment desc_image comment_image) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(name), ref)}
  end

  def handle_event("delete_attachment", %{"id" => id}, socket) do
    attachment = Boards.get_attachment!(id)

    if attachment.card_id == socket.assigns.card.id do
      {:ok, _} = Boards.delete_attachment(attachment)
    end

    {:noreply, socket}
  end

  def handle_event("delete_comment", %{"id" => id}, socket) do
    if comment = Boards.get_comment(subject(socket), id), do: Boards.delete_comment(comment)
    {:noreply, socket}
  end

  ## Events: dependencies -----------------------------------------------------

  def handle_event("dep_direction", %{"direction" => dir}, socket)
      when dir in ~w(blocked_by blocks) do
    {:noreply, socket |> assign(dep_direction: dir) |> assign_dep_results()}
  end

  def handle_event("dep_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(dep_query: q) |> assign_dep_results()}
  end

  def handle_event("add_dependency", %{"id" => id}, socket) do
    %{card: card, dep_direction: direction} = socket.assigns
    other = Boards.get_card!(id)

    result =
      case direction do
        "blocked_by" -> Boards.add_dependency(card, other)
        "blocks" -> Boards.add_dependency(other, card)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket |> assign(dep_query: "", dep_results: []) |> update(:form_key, &(&1 + 1))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("link_search", params, socket) do
    kind =
      if params["kind"] in CardLink.kind_keys(),
        do: params["kind"],
        else: socket.assigns.link_kind

    {:noreply,
     socket |> assign(link_kind: kind, link_query: params["q"] || "") |> assign_link_results()}
  end

  def handle_event("add_link", %{"id" => id}, socket) do
    %{card: card, link_kind: kind, current_user: user} = socket.assigns
    other = Boards.get_card!(id)

    with true <-
           Access.can_read?(Access.card_permission(user, other)) ||
             {:error, "You can't see that card."},
         {:ok, _} <- Boards.add_link(card, other, kind) do
      {:noreply,
       socket
       |> assign(link_query: "", link_results: [], card: Boards.get_card!(card.id))
       |> update(:form_key, &(&1 + 1))}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("remove_link", %{"id" => id}, socket) do
    card = socket.assigns.card
    link = Boards.get_link!(id)

    if link.from_id == card.id or link.to_id == card.id do
      {:ok, _} = Boards.remove_link(link)
      {:noreply, assign(socket, card: Boards.get_card!(card.id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_card_url", params, socket) do
    case Boards.add_card_url(subject(socket), Map.take(params, ["url", "title"])) do
      {:ok, _} ->
        {:noreply, socket |> reload_subject() |> update(:form_key, &(&1 + 1))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "That link #{url_error(changeset)}.")}
    end
  end

  def handle_event("remove_card_url", %{"id" => id}, socket) do
    url = Boards.get_card_url!(id)

    if Owned.owner_ref(url) == item_ref_of(subject(socket)) do
      {:ok, _} = Boards.delete_card_url(url)
      {:noreply, reload_subject(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_dependency", %{"id" => id}, socket) do
    {:ok, _} = Boards.remove_dependency(socket.assigns.card, Boards.get_card!(id))
    {:noreply, socket}
  end

  ## Events: subcards ---------------------------------------------------------

  def handle_event("pick_template", _, socket) do
    {:noreply, update(socket, :picking_template, &(!&1))}
  end

  def handle_event("create_sub_board", %{"template" => id}, socket) do
    case Boards.create_sub_board(socket.assigns.card, Boards.get_template!(id)) do
      {:ok, _} -> {:noreply, assign(socket, picking_template: false)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_sub_board", _, socket) do
    case Boards.delete_sub_board(socket.assigns.card) do
      {:ok, _} -> {:noreply, socket}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Only into a list on the open card's own subcards board.
  def handle_event("quick_add_subcard", %{"column_id" => column_id, "title" => title}, socket) do
    column =
      case socket.assigns.card do
        %Card{sub_board: %Board{id: sub_id}} ->
          Boards.get_board_column(sub_id, column_id)

        _ ->
          nil
      end

    if column && String.trim(title) != "" do
      {:ok, _} = Boards.create_card(column, %{"title" => String.trim(title)})
    end

    {:noreply, update(socket, :form_key, &(&1 + 1))}
  end

  def handle_event("toggle_subcard", %{"id" => id}, socket) do
    card = Boards.get_card!(id)

    if socket.assigns.card && card.board_id == socket.assigns.card.sub_board.id do
      Boards.toggle_completed(card)
    end

    {:noreply, socket}
  end

  ## Events: tags -------------------------------------------------------------

  ## Events: board settings ----------------------------------------------------

  def handle_event("set_field", %{"field_id" => id, "value" => value}, socket) do
    case Enum.find(socket.assigns.board.fields, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, socket}

      field ->
        case Fields.set_value(subject(socket), field, value) do
          {:ok, _} -> {:noreply, reload_subject(socket)}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  def handle_event("vote", %{"count" => count}, socket) do
    case subject(socket) do
      nil ->
        {:noreply, socket}

      subject ->
        with count when is_integer(count) <- Params.int(count),
             {:ok, _} <- Votes.set(subject, socket.assigns.current_user, count) do
          {:noreply, reload_subject(socket)}
        else
          nil -> {:noreply, socket}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

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

  # What may be shared, by whom: the board and its views by the owner; a card
  # by the owner or anyone who can edit it.
  defp share_target(%{assigns: %{can_manage: true, swim_view: %{} = view}}, "view"),
    do: {:ok, view}

  defp share_target(%{assigns: %{card: %Card{} = card} = a}, "card")
       when a.can_manage or a.card_can_write,
       do: {:ok, card}

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

  defp refresh_grants(socket, "card"),
    do: assign(socket, card_grants: Access.list_grants(socket.assigns.card))

  defp refresh_grants(socket, "view"),
    do: assign(socket, view_grants: Access.list_grants(socket.assigns.swim_view))

  # A card on this board (or one of its sub-boards) the user may edit.
  # Whether a card is on this board or any board beneath it.
  defp in_tree?(%{assigns: %{board: board}}, card),
    do: card.board_id == board.id or Slipdock.Rollup.member?(board.rollup, card)

  @time_fields ~w(time_spent time_estimate time_unit)

  defp time_target(%{"_target" => ["card", field]}) when field in @time_fields, do: [field]
  defp time_target(_), do: []

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

  # A tag of this board's tree (they live on the root), or nil.
  defp board_tag(socket, id),
    do: Enum.find(socket.assigns.board.tags, &(to_string(&1.id) == to_string(id)))

  # A wiki page the user may read, to attach to the open card.
  defp readable_page(socket, id) do
    with {:ok, page} <- Wiki.find_page(id),
         true <- Access.can_read?(Access.page_permission(socket.assigns.current_user, page)) do
      {:ok, page}
    else
      _ -> :error
    end
  end

  defp assign_dep_results(%{assigns: %{card: %Card{} = card, dep_query: q}} = socket)
       when q != "" do
    linked = Enum.map(card.blocked_by ++ card.blocks, & &1.id)
    assign(socket, dep_results: Boards.search_cards(card.board_id, q, [card.id | linked]))
  end

  defp assign_dep_results(socket), do: assign(socket, dep_results: [])

  # Cards on any board the user can open, minus this card and those already linked.
  defp assign_link_results(%{assigns: %{card: %Card{} = card, link_query: q}} = socket)
       when q != "" do
    %{current_user: user, board: board} = socket.assigns

    root_ids =
      Enum.uniq([
        Slipdock.Boards.Board.root_id(board)
        | Enum.map(Access.list_boards(user, archived: :all), & &1.id)
      ])

    linked = Enum.map(card.links_out, & &1.to_id) ++ Enum.map(card.links_in, & &1.from_id)
    assign(socket, link_results: Boards.search_cards_across(root_ids, q, [card.id | linked]))
  end

  defp assign_link_results(socket), do: assign(socket, link_results: [])

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

  # Where the keyboard is, for one card: pointing at it, carrying it, or
  # somewhere else entirely.
  # The keyboard cursor walks cards. A placed wiki page is drawn beside them
  # but is not in `col.cards`, so it is never the cursor — and must not light
  # up because it happens to share a card's number.
  defp card_focus(_focus, %Slipdock.Wiki.Page{}), do: nil
  defp card_focus(%{card_id: id, holding?: true}, %{id: id}), do: :held
  defp card_focus(%{card_id: id}, %{id: id}), do: :cursor
  defp card_focus(_focus, _card), do: nil

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

  ## Render helpers -----------------------------------------------------------

  ## Render -------------------------------------------------------------------

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
        <nav class="flex min-w-0 items-center gap-1 text-sm">
          <.link
            navigate={~p"/"}
            class="hidden shrink-0 text-base-content/50 hover:text-base-content sm:inline"
          >
            Boards
          </.link>
          <.icon
            name="hero-chevron-right"
            class="hidden size-3 shrink-0 text-base-content/40 sm:inline"
          />
          <span
            :for={%{board: b, card: c} <- @ancestry}
            class="hidden min-w-0 items-center gap-1 text-base-content/50 lg:flex"
          >
            <.link
              navigate={~p"/boards/#{b}"}
              class="max-w-40 truncate hover:text-base-content"
              title={b.name}
            >
              {b.name}
            </.link>
            <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
            <.link
              navigate={~p"/boards/#{b}/cards/#{c.id}"}
              class="max-w-40 truncate hover:text-base-content"
              title={c.title}
            >
              {c.title}
            </.link>
            <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
          </span>
          <.link
            :if={@can_manage}
            patch={@paths.settings}
            class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
            title={@board.description || "Board settings"}
          >
            <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
            <span class="truncate font-semibold">{@board.name}</span>
            <span
              :if={@board.code && is_nil(@board.parent_card_id)}
              class="chip chip-line hidden shrink-0 font-mono text-2xs sm:inline-flex"
              title="Board code"
            >
              {@board.code}
            </span>
          </.link>
          <div
            :if={!@can_manage}
            class="flex min-w-0 items-center gap-2 px-2 py-1"
            title={"Shared with you (#{if @can_write, do: "can edit", else: "read only"})"}
          >
            <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
            <span class="truncate font-semibold">{@board.name}</span>
            <span
              :if={@board.code && is_nil(@board.parent_card_id)}
              class="chip chip-line hidden shrink-0 font-mono text-2xs sm:inline-flex"
              title="Board code"
            >
              {@board.code}
            </span>
            <span class="badge badge-ghost badge-xs">{if @can_write, do: "shared", else: "read only"}</span>
          </div>
          <span
            :if={not is_nil(@board.archived_at)}
            class="badge badge-warning badge-xs shrink-0"
            title="This board is archived: it is off the board index and the switcher, but nothing on it is lost."
          >
            archived
          </span>
          <.link
            :for={%{board: pb, card: pc} <- Enum.take(@ancestry, -1)}
            navigate={~p"/boards/#{pb}/cards/#{pc.id}"}
            class="btn btn-ghost btn-xs shrink-0 gap-1"
            title={"Open the parent card: #{pc.title} (on #{pb.name})"}
          >
            <.icon name="hero-arrow-uturn-left" class="size-3.5" />
            <span class="hidden sm:inline">Parent card</span>
          </.link>
        </nav>
      </:nav>
      <:actions>
        <button
          :if={@can_write and !@card_only and Board.sprints?(@board)}
          id="new-sprint"
          type="button"
          class="btn btn-primary btn-sm gap-1.5"
          phx-click="open_new_sprint"
          phx-target="#board-sprints"
          title="Start the next sprint: a dated card with a board of its own"
        >
          <.icon name="hero-rocket-launch" class="size-4" />
          <span class="hidden sm:inline">New sprint</span>
        </button>
        <button
          :if={!@card_only and (Board.sprints?(@board) or @sprint_of)}
          id="sprint-charts"
          type="button"
          class="btn btn-ghost btn-sm gap-1.5"
          phx-click="open_sprint_charts"
          phx-target="#board-sprints"
          title={
            if Board.sprints?(@board),
              do: "Velocity across the sprints, and a sprint's burndown",
              else: "This sprint's burndown"
          }
        >
          <.icon name="hero-chart-bar" class="size-4" />
          <span class="hidden sm:inline">Charts</span>
        </button>
        <button
          :if={@can_write and !@card_only and @sprint_of}
          id="sprint-add-cards"
          type="button"
          class="btn btn-primary btn-sm gap-1.5"
          phx-click="open_sprint_picker"
          phx-target="#board-sprints"
          phx-value-id={@sprint_of.id}
          title={"Pick cards from your boards to add to #{@sprint_of.title}"}
        >
          <.icon name="hero-queue-list" class="size-4" />
          <span class="hidden sm:inline">Add cards…</span>
        </button>
        <button
          :if={@ai? and !@card_only}
          type="button"
          class="btn btn-ghost btn-sm gap-1.5"
          title="Chat about this page with AI"
          phx-click="toggle"
          phx-target="#page-ai"
        >
          <.icon name="hero-sparkles" class="size-4" />
          <span class="hidden md:inline">Chat</span>
        </button>
        <.link
          :if={@can_manage and !@card_only}
          patch={@paths.settings}
          class="btn btn-ghost btn-sm hidden gap-1.5 sm:inline-flex"
          title="Share this board"
        >
          <.icon name="hero-user-plus" class="size-4" />
          <span class="hidden md:inline">Share</span>
        </.link>
        <div :if={!@view_only and !@card_only} class="dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost btn-sm btn-square" title="More">
            <.icon name="hero-ellipsis-horizontal" class="size-4" />
          </div>
          <ul
            tabindex="0"
            class="menu dropdown-content z-40 mt-2 w-52 rounded-box bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
          >
            <li :if={@can_manage} class="sm:hidden">
              <.link patch={@paths.settings}>
                <.icon name="hero-user-plus" class="size-4" /> Share this board
              </.link>
            </li>
            <li>
              <.link patch={@paths.tags}><.icon name="hero-tag" class="size-4" /> Tags</.link>
            </li>
            <li>
              <.link patch={@paths.activity}><.icon name="hero-bolt" class="size-4" /> Activity</.link>
            </li>
            <li>
              <.link patch={@paths.archive}>
                <.icon name="hero-archive-box" class="size-4" /> Archived cards
              </.link>
            </li>
            <li :if={@can_manage}>
              <.link patch={@paths.automations}>
                <.icon name="hero-cpu-chip" class="size-4" /> Automations
                <span :if={@rules != []} class="badge badge-ghost badge-xs">{length(@rules)}</span>
              </.link>
            </li>
            <li :if={@can_manage}>
              <.link patch={@paths.settings}>
                <.icon name="hero-cog-6-tooth" class="size-4" /> Board settings
              </.link>
            </li>
          </ul>
        </div>
      </:actions>

      <div :if={@mode == :table and !@card_only} class="flex h-full flex-col">
        <.swim_toolbar
          mode={:table}
          board={@board}
          config={@swim}
          view={@swim_view}
          dirty={@swim_dirty}
          grid={@grid}
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
            narrow={@narrow?}
            board={@board}
            config={@swim}
            rows={@table_rows}
            collapsed={@swim_collapsed}
            form_key={@form_key}
            can_write={@can_write}
            quick_preview={@quick_preview}
          />
        </div>
      </div>

      <div :if={@mode == :timeline and !@card_only} class="flex h-full flex-col">
        <.swim_toolbar
          mode={:timeline}
          board={@board}
          config={@swim}
          view={@swim_view}
          dirty={@swim_dirty}
          grid={@grid}
          nav={Map.take(@timeline, [:title, :prev, :next])}
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
          <.timeline_view
            narrow={@narrow?}
            board={@board}
            config={@swim}
            timeline={@timeline}
            collapsed={@swim_collapsed}
            form_key={@form_key}
            can_write={@can_write}
          />
        </div>
      </div>

      <div :if={@mode == :outline and !@card_only} class="flex h-full flex-col">
        <.swim_toolbar
          mode={:outline}
          board={@board}
          config={@swim}
          view={@swim_view}
          dirty={@swim_dirty}
          grid={@grid}
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
          <.outline_view
            board={@board}
            config={@swim}
            outline={@outline}
            collapsed={@swim_collapsed}
            can_write={@can_write}
            quick_preview={@quick_preview}
          />
        </div>
      </div>

      <div :if={@mode == :prioritise and !@card_only} class="flex h-full flex-col">
        <.swim_toolbar
          mode={:prioritise}
          board={@board}
          config={@swim}
          view={@swim_view}
          dirty={@swim_dirty}
          grid={@grid}
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
          <.prioritise_view
            narrow={@narrow?}
            board={@board}
            config={@swim}
            prioritise={@prioritise}
            can_write={@can_write}
            can_manage={@can_manage}
            current_user={@current_user}
          />
        </div>
      </div>

      <div :if={@mode == :narrative and !@card_only} class="flex h-full flex-col">
        <.swim_toolbar
          mode={:narrative}
          board={@board}
          config={@swim}
          view={@swim_view}
          dirty={@swim_dirty}
          grid={@grid}
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
          <.narrative_view
            board={@board}
            config={@swim}
            narrative={@narrative}
            collapsed={@swim_collapsed}
            can_write={@can_write}
            view_name={@swim_view && @swim_view.name}
            ai={@ai?}
            current_user={@current_user}
          />
        </div>
      </div>

      <div :if={@mode == :calendar and !@card_only} class="flex h-full flex-col">
        <.swim_toolbar
          mode={:calendar}
          board={@board}
          config={@swim}
          view={@swim_view}
          dirty={@swim_dirty}
          grid={@grid}
          nav={Map.take(@calendar, [:title, :prev, :next])}
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
          <.calendar_view
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
        </div>
      </div>

      <div :if={@mode == :swimlanes and !@card_only} class="flex h-full flex-col">
        <.swim_toolbar
          board={@board}
          config={@swim}
          view={@swim_view}
          dirty={@swim_dirty}
          grid={@grid}
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
          <.swim_grid
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

      <div :if={@mode == :board and !@card_only} class="flex h-full flex-col">
        <.board_toolbar
          board={@board}
          filters={@filters}
          filtering={@filtering}
          columns={@columns}
          config={@swim}
          view={@swim_view}
          dirty={@swim_dirty}
          form_key={@form_key}
          can_write={@can_write}
          can_manage={@can_manage}
          view_only={@view_only}
          view_grants={@view_grants}
          groups={@groups}
          share_key={@share_key}
          marks={@favourites}
        />
        <div
          :if={@filtering}
          class="flex flex-wrap items-center gap-2 border-b border-base-300 bg-base-100/60 px-4 py-2 text-sm"
        >
          <span class="text-base-content/60">Showing cards matching:</span>
          <span :if={@filters.q != ""} class="badge badge-outline gap-1">
            “{@filters.q}”
          </span>
          <span :for={kind <- @filters.kinds} class="badge badge-outline">
            {Slipdock.Kinds.label(kind)} only
          </span>
          <span :for={id <- @filters.tags} :if={tag_by_id(@board, id)}>
            <.tag_chip tag={tag_by_id(@board, id)} />
          </span>
          <span :if={@filters.priority} class="badge badge-outline">{priority_label(@filters.priority)} priority</span>
          <span :if={@filters.flag} class="badge badge-outline">{flag_label(@filters.flag)}</span>
          <span :if={@filters.due} class="badge badge-outline">
            {%{"overdue" => "Overdue", "week" => "Due in 7 days", "none" => "No due date"}[
              @filters.due
            ]}
          </span>
          <span :if={@filters.hide_completed} class="badge badge-outline">Completed hidden</span>
          <button class="btn btn-ghost btn-xs" phx-click="clear_filters">
            <.icon name="hero-x-mark" class="size-3.5" /> Clear
          </button>
        </div>

        <.list_pager :if={@narrow? and @columns != []} columns={@columns} />

        <div
          id="board-scroll"
          phx-hook="ScrollEnd"
          class={[
            "kanban-scroll min-h-0 flex-1 overflow-x-auto overflow-y-hidden",
            @narrow? && "snap-x snap-mandatory scroll-pl-4"
          ]}
        >
          <div
            id="columns"
            phx-hook="Sortable"
            data-group="columns"
            data-draggable=".kanban-column"
            data-handle=".column-handle"
            data-event="move_column"
            data-disabled={to_string(!@can_write)}
            class="flex h-full items-start gap-4 p-4"
          >
            <div
              :for={%{column: column, cards: cards, items: items, hidden: hidden} <- @columns}
              id={"column-#{column.id}"}
              data-id={column.id}
              class={[
                "kanban-column flex max-h-full shrink-0 flex-col rounded-2xl bg-base-300/60 shadow-inner",
                if(@narrow?, do: "w-[calc(100vw-2.5rem)] snap-start", else: "w-72"),
                @focus && @focus.column_id == column.id && "ring-2 ring-secondary/50"
              ]}
            >
              <div class="column-handle flex cursor-grab items-center gap-2 px-3 pb-1 pt-3 active:cursor-grabbing">
                <span
                  :if={column.color}
                  class={["size-2.5 shrink-0 rounded-full", Palette.dot(column.color)]}
                ></span>
                <form
                  :if={@renaming_column == column.id}
                  phx-submit="rename_column"
                  class="flex-1"
                >
                  <input type="hidden" name="column_id" value={column.id} />
                  <input
                    type="text"
                    name="name"
                    value={column.name}
                    class="input input-sm w-full font-semibold"
                    phx-hook="Focus"
                    data-select
                    phx-blur="cancel_rename_column"
                    phx-window-keydown="cancel_rename_column"
                    phx-key="Escape"
                    id={"rename-#{column.id}"}
                  />
                </form>
                <h2
                  :if={@renaming_column != column.id}
                  class={[
                    "min-w-0 flex-1 truncate rounded px-1 text-sm font-semibold",
                    @can_write && "cursor-text hover:bg-base-100/60"
                  ]}
                  phx-click={@can_write && "start_rename_column"}
                  phx-value-id={column.id}
                  title={@can_write && "Click to rename"}
                >
                  {column.name}
                </h2>
                <span
                  :if={Column.horizon?(column)}
                  class="chip chip-line max-w-28 shrink-0 truncate text-2xs"
                  title={"This list stands for #{Column.horizon_label(column)}"}
                >
                  {Column.horizon_label(column)}
                </span>
                <% drifted = Enum.count(cards, &Column.drifted?(column, Card.effective_due(&1))) %>
                <span
                  :if={drifted > 0}
                  class="chip bg-amber-500/15 text-2xs text-amber-700 dark:text-amber-300"
                  title={"#{drifted} #{if drifted == 1, do: "card is", else: "cards are"} due outside this horizon"}
                >
                  <.icon name="hero-arrow-uturn-right" class="size-3" /> {drifted}
                </span>
                <span
                  class={[
                    "badge badge-sm font-mono",
                    cond do
                      column.wip_limit && length(column.cards) > column.wip_limit -> "badge-error"
                      column.wip_limit && length(column.cards) == column.wip_limit -> "badge-warning"
                      true -> "badge-ghost"
                    end
                  ]}
                  title={
                    if column.wip_limit,
                      do: "WIP limit #{column.wip_limit}",
                      else: "#{length(column.cards)} cards"
                  }
                >
                  {if column.wip_limit,
                    do: "#{length(column.cards)}/#{column.wip_limit}",
                    else: length(column.cards)}
                </span>
                <.favourite_toggle
                  kind="column"
                  id={column.id}
                  name={column.name}
                  marks={@favourites}
                  class="p-0.5"
                  size="size-3.5"
                />
                <div :if={@can_write} class="dropdown dropdown-end">
                  <div
                    tabindex="0"
                    role="button"
                    class="btn btn-ghost btn-xs btn-square"
                    title="List actions"
                  >
                    <.icon name="hero-ellipsis-horizontal" class="size-4" />
                  </div>
                  <ul
                    tabindex="0"
                    class="menu dropdown-content z-30 w-48 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
                  >
                    <li>
                      <button phx-click="start_add_card" phx-value-id={column.id}>
                        <.icon name="hero-plus" class="size-4" /> Add card
                      </button>
                    </li>
                    <li>
                      <button
                        phx-click="edit_column"
                        phx-target="#board-column"
                        phx-value-id={column.id}
                      >
                        <.icon name="hero-cog-6-tooth" class="size-4" /> List settings
                      </button>
                    </li>
                    <li>
                      <button
                        class="text-error"
                        phx-click="delete_column"
                        phx-target="#board-column"
                        phx-value-id={column.id}
                        data-confirm={"Delete “#{column.name}” and its #{length(column.cards)} cards?"}
                      >
                        <.icon name="hero-trash" class="size-4" /> Delete list
                      </button>
                    </li>
                  </ul>
                </div>
              </div>

              <div
                id={"cards-#{column.id}"}
                data-id={column.id}
                phx-hook="Sortable"
                data-group="cards"
                data-event="move_card"
                data-disabled={to_string(!@can_write)}
                class="kanban-scroll min-h-[2.5rem] flex-1 space-y-2 overflow-y-auto px-2 py-1"
              >
                <%!-- Cards and placed wiki pages are drawn by the same
                      component: a page carries the card's facets, and the one
                      thing it does differently is the document icon. --%>
                <.card
                  :for={{_kind, item} <- items}
                  card={item}
                  compact={@swim.density == "compact"}
                  show={Config.shown(@swim)}
                  focus={@focus && card_focus(@focus, item)}
                >
                  <:actions :if={@can_write and length(@board.columns) > 1}>
                    <.move_menu card={item} board={@board} />
                  </:actions>
                </.card>
                <p :if={hidden > 0} class="px-1 py-1 text-center text-2xs text-base-content/60">
                  {hidden} hidden by filters
                </p>
              </div>

              <div :if={@can_write} class="p-2">
                <form
                  :if={@adding_to == column.id}
                  id={"quick-add-#{column.id}-#{@form_key}"}
                  phx-submit="quick_add_card"
                  class="kanban-pop space-y-2"
                >
                  <input type="hidden" name="column_id" value={column.id} />
                  <input
                    type="text"
                    name="title"
                    placeholder="Card title, then Enter"
                    class="input input-sm w-full"
                    phx-hook="Focus"
                    id={"quick-add-input-#{column.id}-#{@form_key}"}
                    phx-window-keydown="cancel_add_card"
                    phx-key="Escape"
                    autocomplete="off"
                    required
                  />
                  <div class="flex items-center gap-1">
                    <button type="submit" class="btn btn-primary btn-sm">Add card</button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-sm btn-square"
                      phx-click="cancel_add_card"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                </form>
                <%!-- The three are shortcuts to the same thing: something new
                      at the foot of this list. One row of icons rather than
                      three rows of words — a list is narrow, and what is in
                      it matters more than how to add to it. Each can be
                      turned off in the board's settings. --%>
                <div :if={@adding_to != column.id} class="flex items-center gap-0.5">
                  <button
                    :if={@board.add_card}
                    type="button"
                    class="btn btn-ghost btn-sm gap-1.5 px-2 text-base-content/50 hover:text-base-content"
                    phx-click="start_add_card"
                    phx-value-id={column.id}
                    title="Add a card"
                    aria-label={"Add a card to #{column.name}"}
                  >
                    <.icon name="hero-plus" class="size-4" />
                    <span class="text-xs font-normal">Add</span>
                  </button>
                  <%!-- Straight into the wiki's own editor, carrying the
                        list: a page is written as Markdown, not filled into a
                        card form, and it is placed here when it is saved. --%>
                  <.link
                    :if={@board.add_page}
                    navigate={~p"/boards/#{@board}/wiki/new?#{[column: column.id]}"}
                    class="btn btn-ghost btn-sm btn-square text-base-content/50 hover:text-base-content"
                    title="Add a page — a wiki document, written here and placed in this list"
                    aria-label={"Add a page to #{column.name}"}
                  >
                    <.icon name="hero-document-text" class="size-4" />
                  </.link>
                  <%!-- One hidden file input for the whole board (one per
                        list would be a duplicate id), opened from here. The
                        click is dispatched at it rather than reaching it
                        through a label's `for`: that way the same gesture
                        records which list the file belongs to, which the
                        upload that follows has no way of knowing. --%>
                  <button
                    :if={@board.add_document}
                    type="button"
                    class="btn btn-ghost btn-sm btn-square text-base-content/50 hover:text-base-content"
                    title="Add a document — a file, on a card of its own"
                    aria-label={"Add a document to #{column.name}"}
                    phx-click={
                      JS.push("aim_document", value: %{id: column.id})
                      |> JS.dispatch("click", to: "##{@uploads.list_document.ref}")
                    }
                  >
                    <.icon name="hero-paper-clip" class="size-4" />
                  </button>
                </div>
              </div>
            </div>

            <%!-- A `live_file_input` has to sit inside a form with a change
                  binding: LiveView picks the file up from the form's change
                  event, so a bare input takes the file and does nothing with
                  it. One form for the whole board — one per list would be a
                  duplicate id — and `aim_document` says which list. --%>
            <form
              :if={@can_write and @board.add_document}
              id="list-document-form"
              phx-change="validate_document"
              phx-submit="validate_document"
            >
              <.live_file_input upload={@uploads.list_document} class="hidden" />
            </form>

            <div :if={@can_write} class="w-72 shrink-0">
              <form
                :if={@adding_column}
                id={"add-column-#{@form_key}"}
                phx-submit="add_column"
                class="kanban-pop space-y-2 rounded-2xl bg-base-300/60 p-2"
              >
                <input
                  type="text"
                  name="name"
                  placeholder="List name"
                  class="input input-sm w-full"
                  phx-hook="Focus"
                  id="add-column-input"
                  phx-window-keydown="cancel_add_column"
                  phx-key="Escape"
                  autocomplete="off"
                  required
                />
                <div class="flex items-center gap-1">
                  <button type="submit" class="btn btn-primary btn-sm">Add list</button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm btn-square"
                    phx-click="cancel_add_column"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
              </form>
              <button
                :if={!@adding_column}
                type="button"
                class="btn btn-ghost w-full justify-start rounded-2xl bg-base-100/40 hover:bg-base-100/80"
                phx-click="start_add_column"
              >
                <.icon name="hero-plus" class="size-4" /> Add another list
              </button>
            </div>
          </div>
        </div>
      </div>

      <div
        id="board-keys"
        phx-hook="BoardKeys"
        data-board={to_string(@mode == :board and !@card_only)}
        data-move={to_string(@mode == :board and @can_write and !@card_only)}
        data-focus={@focus && if(@focus.holding?, do: "hold", else: "point")}
        class="hidden"
      >
      </div>

      <div
        :if={@focus}
        class="kanban-toast-in pointer-events-none fixed bottom-4 left-1/2 z-50 flex max-w-[calc(100vw-2rem)] -translate-x-1/2 items-center gap-2 rounded-full bg-base-content px-4 py-2 text-xs text-base-100 shadow-xl"
      >
        <.icon
          name={if @focus.holding?, do: "hero-arrows-pointing-out", else: "hero-cursor-arrow-rays"}
          class="size-3.5 shrink-0"
        />
        <span class="truncate font-semibold">
          {if @focus.holding?, do: "Moving", else: "On"} “{@focus_title || "an empty list"}”
        </span>
        <span :if={@focus.holding?} class="shrink-0 opacity-70">
          h l or ← → list · j k or ↑ ↓ order · Enter to drop · Esc to stop
        </span>
        <span :if={!@focus.holding?} class="shrink-0 opacity-70">
          h j k l or arrows move · Enter to open · J to pick up · c to add · Esc to stop
        </span>
      </div>

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
      <.page_modal
        :if={@open_page}
        page={@open_page}
        form={@page_form}
        board={@board}
        users={@assignable}
        can_write={@page_can_write}
        current_user={@current_user}
        form_key={@form_key}
      />
      <.card_modal
        :if={@panel == :card and not is_nil(@card) and not @moving_board and not @sprint_picking}
        card={@card}
        ai?={@ai?}
        current_user={@current_user}
        users={@assignable}
        form={@card_form}
        board={@board}
        mention_people={@mention_people}
        form_key={@form_key}
        close_path={@paths.close}
        tags_path={@paths.tags}
        card_link={&card_path(assigns, &1)}
        dep_direction={@dep_direction}
        dep_query={@dep_query}
        dep_results={@dep_results}
        link_kind={@link_kind}
        link_query={@link_query}
        link_results={@link_results}
        templates={@templates}
        picking_template={@picking_template}
        close_navigate={@card_only}
        can_write={@card_can_write}
        can_share={@can_manage or @card_can_write}
        grants={@card_grants}
        pages={@card_pages}
        doc_query={@doc_query}
        doc_results={@doc_results}
        groups={@groups}
        share_key={@share_key}
        uploads={@uploads}
        editing_description={@editing_description}
        parent={List.last(@ancestry)}
        favourites={@favourites}
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
      <.activity_modal
        :if={@panel == :activity}
        board={@board}
        activities={@activities}
        close_path={@paths.close}
      />
      <.archive_modal
        :if={@panel == :archive}
        board={@board}
        archived={@archived}
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

  ## Toolbar -----------------------------------------------------------------

  # {mode, path suffix, label, icon, tooltip, the key that picks it under "v"}.
  attr :card, :any, required: true
  attr :board, :any, required: true

  @doc false
  # "Move to another list", on the card itself.
  #
  # Dragging is the quick way with a mouse and the only way there was — which
  # on a phone means dragging a card across a board that shows one list at a
  # time, holding it at the screen's edge and waiting. This is two taps, and
  # on a desktop it stays out of the way until the card is hovered.
  #
  # The button carries a `phx-click` of its own so the tap stops here:
  # LiveView fires the binding on the closest element that has one, and the
  # card behind this is one big "open me". Focusing itself is that binding —
  # it does nothing, which is the point.
  #
  # The menu is a native popover, which the browser draws in its top layer:
  # an ordinary dropdown here is clipped by the list's own scrollbox, and
  # came out two rows tall. `AnchoredPopover` puts it beside the button.
  defp move_menu(assigns) do
    page? = SlipdockWeb.SlipdockComponents.page?(assigns.card)
    # `page-7` for a page, a bare number for a card — the same id the
    # drag-and-drop sends, read by `Slipdock.Boards.item_ref/1`. A card keeps
    # the ids it always had, so only the pages need a prefix to stay apart.
    item_id = if page?, do: "page-#{assigns.card.id}", else: to_string(assigns.card.id)

    assigns =
      assign(assigns,
        menu_id: "move-menu-#{item_id}",
        anchor_id: "move-#{item_id}",
        item_id: item_id
      )

    ~H"""
    <button
      id={@anchor_id}
      type="button"
      popovertarget={@menu_id}
      phx-click={JS.focus()}
      class="btn btn-ghost btn-xs btn-square text-base-content/40 opacity-0 transition group-hover:opacity-100 focus:opacity-100 no-hover:opacity-100"
      title="Move to another list"
      aria-label={"Move “#{@card.title}” to another list"}
    >
      <.icon name="hero-arrow-right-circle" class="size-4" />
    </button>
    <div
      id={@menu_id}
      popover
      phx-hook="AnchoredPopover"
      data-anchor={@anchor_id}
      class="pop-menu"
    >
      <ul class="menu max-h-[60vh] w-48 flex-nowrap overflow-y-auto rounded-xl bg-base-100 p-1 text-sm shadow-xl ring-1 ring-base-content/10">
        <li class="menu-title px-2 py-1 text-2xs">Move to</li>
        <li :for={column <- @board.columns}>
          <button
            type="button"
            popovertarget={@menu_id}
            popovertargetaction="hide"
            phx-click="move_card"
            phx-value-id={@item_id}
            phx-value-to={column.id}
            disabled={column.id == @card.column_id}
            class={[
              "flex items-center gap-2",
              column.id == @card.column_id && "text-base-content/40"
            ]}
          >
            <span
              :if={column.color}
              class={["size-2 shrink-0 rounded-full", Palette.dot(column.color)]}
            ></span>
            <span class="min-w-0 flex-1 truncate text-left">{column.name}</span>
            <.icon :if={column.id == @card.column_id} name="hero-check" class="size-3.5 shrink-0" />
          </button>
        </li>
        <li class="border-t border-base-content/10 pt-1">
          <button
            type="button"
            popovertarget={@menu_id}
            popovertargetaction="hide"
            phx-click="open_move_board"
            phx-target="#board-move"
            phx-value-id={@card.id}
            class="flex items-center gap-2"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-3.5 shrink-0" />
            <span class="min-w-0 flex-1 truncate text-left">Another board…</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :columns, :list, required: true

  @doc false
  # The phone's list strip. The board is one list wide on a 390pt screen, so
  # this is the map: every list, how full it is, and which one you are on.
  # Tapping one slides the board to it (see the `ListPager` hook); swiping
  # the board moves the highlight back. Nothing here reaches the server.
  defp list_pager(assigns) do
    ~H"""
    <div
      id="list-pager"
      phx-hook="ListPager"
      role="tablist"
      aria-label="Lists"
      class="kanban-scroll flex shrink-0 gap-1 overflow-x-auto border-b border-base-300 bg-base-100/70 px-3 py-1.5"
    >
      <button
        :for={%{column: column, cards: cards} <- @columns}
        type="button"
        role="tab"
        data-column={column.id}
        class="pager-tab flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium text-base-content/60"
      >
        <span
          :if={column.color}
          class={["size-2 shrink-0 rounded-full", Palette.dot(column.color)]}
        ></span>
        <span class="max-w-32 truncate">{column.name}</span>
        <span class="font-mono text-2xs opacity-60">{length(cards)}</span>
      </button>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :filters, :map, required: true
  attr :filtering, :boolean, required: true
  attr :columns, :list, required: true
  attr :config, Config, required: true
  attr :view, :any, default: nil
  attr :dirty, :boolean, default: false
  attr :form_key, :integer, required: true
  attr :can_write, :boolean, default: true
  attr :can_manage, :boolean, default: false
  attr :view_only, :boolean, required: true
  attr :view_grants, :list, default: []
  attr :groups, :list, default: []
  attr :share_key, :integer, default: 0
  attr :marks, :any, default: nil, doc: "the reader's favourites (`Slipdock.Favourites.marks/1`)"

  # Board view's toolbar: the view switcher, search, filters, display options,
  # saved views and the count, laid out like `swim_toolbar/1` so nothing
  # moves when switching views.
  defp board_toolbar(assigns) do
    shown = Enum.sum(for %{cards: cards} <- assigns.columns, do: length(cards))
    hidden = Enum.sum(for %{hidden: hidden} <- assigns.columns, do: hidden)
    assigns = assign(assigns, shown: shown, hidden: hidden)

    ~H"""
    <div class="flex flex-wrap items-center gap-x-2 gap-y-2 border-b border-base-300 bg-base-100/70 px-3 py-2 text-sm">
      <.view_tabs
        :if={!@view_only}
        board={@board}
        mode={:board}
        config={@config}
        view={@view}
        marks={@marks}
      />
      <span class="hidden h-5 w-px bg-base-300 sm:block"></span>

      <form id="board-search" phx-change="search" phx-submit="search" class="relative">
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
        />
        <input
          type="search"
          name="q"
          value={@filters.q}
          placeholder="Search cards…"
          phx-debounce="200"
          class="input input-sm w-40 rounded-full pl-8 transition-[width] focus:w-64"
          autocomplete="off"
        />
      </form>

      <.filter_menu board={@board} filters={@filters} filtering={@filtering} />

      <form id="swim-config" phx-change="swim_config" phx-submit="swim_config" class="contents">
        <.display_menu mode={:board} config={@config} />
      </form>

      <div class="ml-auto flex items-center gap-2">
        <span class="hidden text-xs text-base-content/50 lg:inline" title="Cards shown">
          {@shown} {if @shown == 1, do: "card", else: "cards"}<span :if={@hidden > 0}> · {@hidden} hidden</span>
        </span>
        <.view_controls
          board={@board}
          mode={:board}
          view={@view}
          dirty={@dirty}
          can_write={@can_write}
          can_manage={@can_manage}
          view_only={@view_only}
          view_grants={@view_grants}
          groups={@groups}
          share_key={@share_key}
          form_key={@form_key}
          favourites={@marks}
        />
      </div>
    </div>
    """
  end

  ## Modals -------------------------------------------------------------------

  attr :card, :map, required: true

  defp contributions_bar(assigns) do
    contributions = Card.contributions(assigns.card)

    assigns =
      assign(assigns,
        total: length(contributions),
        done: Enum.count(contributions, & &1.completed)
      )

    ~H"""
    <div :if={@total > 0} class="flex items-center gap-2 text-xs" id="card-contributions">
      <progress class="progress progress-primary h-1.5 w-24" value={@done} max={@total}></progress>
      <span class="font-mono text-base-content/70">{@done}/{@total}</span>
      <span class="text-base-content/50">contributions done</span>
    </div>
    """
  end

  attr :page, :any, required: true
  attr :form, :any, required: true
  attr :board, :any, required: true
  attr :users, :list, required: true
  attr :can_write, :boolean, required: true
  attr :current_user, :any, default: nil
  attr :form_key, :integer, default: 0

  # A page's panel is the card's panel without the card's *body*: the
  # document is a click away and is where the writing happens. Everything
  # else a card's panel says — where it stands, and what has been said about
  # it — a page says here, with the same components and the same events.
  defp page_modal(assigns) do
    assigns = assign(assigns, tags: Wiki.tags(assigns.page))

    ~H"""
    <.modal id="page-panel" on_close={JS.push("close_page")} size="md">
      <div class="space-y-4 p-4 sm:p-6">
        <div class="flex items-start gap-3">
          <.icon name="hero-document-text" class="mt-1 size-5 shrink-0 text-primary/70" />
          <div class="min-w-0 flex-1">
            <h2 class="text-lg font-semibold leading-snug">{@page.title}</h2>
            <p class="mt-0.5 text-xs text-base-content/50">
              <span class="font-mono">{@page.code}</span>
              <span :if={@page.summary}> · {@page.summary}</span>
            </p>
          </div>
          <.link
            navigate={~p"/boards/#{@board}/wiki/#{@page.slug}"}
            class="btn btn-primary btn-sm shrink-0 gap-1.5"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open the document
          </.link>
        </div>

        <p :if={not @can_write} class="rounded-lg bg-base-200 px-3 py-2 text-sm text-base-content/60">
          You have read-only access to this page.
        </p>

        <.form
          :if={@can_write}
          for={@form}
          id="page-panel-form"
          phx-change="page_change"
          class="space-y-3"
        >
          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              field={@form[:priority]}
              type="select"
              label="Priority"
              options={priority_options()}
            />
            <.input
              field={@form[:assignee_id]}
              type="select"
              label="Assignee"
              options={[
                {"Nobody", ""}
                | Enum.map(
                    assignee_options(@users, @page.assignee_id),
                    &{Accounts.User.display_name(&1), &1.id}
                  )
              ]}
            />
            <.input field={@form[:start_date]} type="date" label="Start" />
            <.input field={@form[:due_date]} type="date" label="Due" />
            <.input
              field={@form[:date_precision]}
              type="select"
              label="Date precision"
              options={Enum.map(Dates.precisions(), fn {k, l} -> {l, k} end)}
            />
            <.input
              field={@form[:percent_complete]}
              type="number"
              label="% complete"
              min="0"
              max="100"
            />
            <.input
              field={@form[:color]}
              type="select"
              label="Cover colour"
              options={[{"None", ""} | Enum.map(Palette.names(), &{String.capitalize(&1), &1})]}
            />
            <.input
              field={@form[:status]}
              type="select"
              label="Visibility"
              options={[{"Published", "published"}, {"Draft — writers only", "draft"}]}
            />
          </div>
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="page[completed]" value="false" />
            <input
              type="checkbox"
              name="page[completed]"
              value="true"
              checked={@page.completed}
              class="checkbox checkbox-sm"
            /> Written
          </label>
        </.form>

        <div class="space-y-1.5">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Flags</p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={flag <- Card.flags()}
              type="button"
              disabled={not @can_write}
              phx-click="page_toggle_flag"
              phx-value-flag={flag}
              class={[
                "chip gap-1",
                if(flag in @page.flags, do: "bg-primary/15 text-primary", else: "chip-line")
              ]}
            >
              <.flag_icon flag={flag} class="size-3.5" /> {flag}
            </button>
          </div>
        </div>

        <div :if={@board.tags != []} class="space-y-1.5">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Tags</p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={tag <- @board.tags}
              type="button"
              disabled={not @can_write}
              phx-click="page_toggle_tag"
              phx-value-id={tag.id}
              class={[
                "chip",
                if(Enum.any?(@tags, &(&1.id == tag.id)),
                  do: Palette.chip(tag.color),
                  else: "chip-line"
                )
              ]}
            >
              {tag.name}
            </button>
          </div>
        </div>

        <%!-- The card contents a page carries. Same components the card panel
              draws, same events: a page is read here exactly as a card is. --%>
        <div class="space-y-5 border-t border-base-300 pt-4">
          <.status_section item={@page} can_write={@can_write} form_key={@form_key} />
          <.checklist_section item={@page} can_write={@can_write} form_key={@form_key} />
          <.urls_section item={@page} can_write={@can_write} form_key={@form_key} />
          <.fields_section item={@page} board={@board} can_write={@can_write} />
          <.vote_box
            item={@page}
            board={@board}
            current_user={@current_user}
            can_write={@can_write}
          />
          <.comments_section
            item={@page}
            board={@board}
            current_user={@current_user}
            can_write={@can_write}
            form_key={@form_key}
          />
        </div>

        <div class="flex flex-wrap items-center gap-2 border-t border-base-300 pt-3 text-sm">
          <span class="text-base-content/50">
            In {column_name(@board, @page.column_id) || "no list"}
          </span>
          <button
            :if={@can_write and @page.column_id}
            type="button"
            phx-click="unplace_page"
            phx-value-id={@page.id}
            class="btn btn-ghost btn-xs"
          >
            Take it off the board
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  attr :card, Card, required: true
  attr :users, :list, required: true
  attr :form, :any, required: true
  attr :board, :any, required: true
  attr :form_key, :integer, required: true
  attr :close_path, :string, required: true
  attr :tags_path, :string, required: true
  attr :card_link, :any, required: true, doc: "fn card_id -> path"
  attr :link_kind, :string, default: "relates"
  attr :link_query, :string, default: ""
  attr :link_results, :list, default: []
  attr :dep_direction, :string, required: true
  attr :dep_query, :string, required: true
  attr :dep_results, :list, required: true
  attr :templates, :list, required: true
  attr :picking_template, :boolean, required: true
  attr :mention_people, :string, default: nil
  attr :can_write, :boolean, required: true
  attr :can_share, :boolean, required: true
  attr :grants, :list, required: true
  attr :pages, :list, default: [], doc: "the wiki pages that talk about this card"
  attr :doc_query, :string, default: "", doc: "what is typed into the Docs picker"
  attr :doc_results, :list, default: [], doc: "pages the Docs picker is offering"
  attr :groups, :list, required: true
  attr :share_key, :integer, required: true
  attr :uploads, :map, required: true
  attr :editing_description, :boolean, required: true
  attr :close_navigate, :boolean, default: false
  attr :parent, :any, default: nil
  attr :ai?, :boolean, default: false, doc: "offer the AI assistant on the card"

  attr :current_user, :any, default: nil

  attr :favourites, :any,
    default: nil,
    doc: "the reader's favourites (`Slipdock.Favourites.marks/1`)"

  defp card_modal(assigns) do
    {done, total, pct} = checklist_progress(assigns.card.checklist_items)
    assigns = assign(assigns, done: done, total: total, pct: pct)

    ~H"""
    <.modal
      id="card-modal"
      on_close={if @close_navigate, do: JS.navigate(@close_path), else: JS.patch(@close_path)}
      size="lg"
      keys
    >
      <%!-- Outside the fieldset below, which is disabled for a read-only
            card: a favourite is the reader's own, not a change to the card. --%>
      <.favourite_toggle
        kind="card"
        id={@card.id}
        name={@card.title}
        marks={@favourites}
        class="btn btn-ghost btn-sm btn-circle absolute right-12 top-3 z-10"
        size="size-5"
      />
      <div
        :if={@card.color}
        class={["h-3 rounded-t-2xl bg-gradient-to-r", Palette.gradient(@card.color)]}
      >
      </div>
      <p
        :if={!@can_write}
        class="flex items-center gap-2 bg-base-200 px-6 py-1.5 text-xs text-base-content/60"
      >
        <.icon name="hero-lock-closed" class="size-3.5" /> You have read-only access to this card.
      </p>
      <.link
        :if={@parent}
        navigate={~p"/boards/#{@parent.board}/cards/#{@parent.card.id}"}
        class="flex min-w-0 items-center gap-1.5 bg-base-200/60 px-6 py-1.5 text-xs text-base-content/60 hover:text-base-content"
        title={"Back to parent card: #{@parent.card.title}"}
      >
        <.icon name="hero-arrow-uturn-left" class="size-3.5 shrink-0" />
        <span class="shrink-0">Parent card</span>
        <span class="truncate font-medium">{@parent.card.title}</span>
        <span class="shrink-0 text-base-content/40">on {@parent.board.name}</span>
      </.link>
      <fieldset disabled={!@can_write} class="contents">
        <div class="grid grid-cols-1 md:grid-cols-[minmax(0,1fr)_260px]">
          <div class="min-w-0 space-y-7 p-6">
            <.form
              for={@form}
              id="card-form"
              phx-change="card_change"
              phx-submit="card_change"
              class="space-y-3"
            >
              <div class="flex items-start gap-3 pr-8">
                <button
                  type="button"
                  class={[
                    "mt-1.5 shrink-0",
                    if(@card.completed,
                      do: "text-success",
                      else: "text-base-content/30 hover:text-success"
                    )
                  ]}
                  phx-click="toggle_complete"
                  phx-value-id={@card.id}
                  title={if @card.completed, do: "Mark incomplete", else: "Mark complete"}
                >
                  <.icon
                    name={
                      if @card.completed, do: "hero-check-circle-solid", else: "hero-check-circle"
                    }
                    class="size-6"
                  />
                </button>
                <textarea
                  name={@form[:title].name}
                  id="card-title"
                  rows="1"
                  phx-debounce="500"
                  phx-hook="AutoGrow"
                  data-single-line
                  class={[
                    "w-full resize-none rounded-lg bg-transparent px-1 text-xl font-bold leading-tight outline-none ring-primary/40 focus:bg-base-200/60 focus:ring-2 sm:text-2xl",
                    @card.completed && "opacity-60"
                  ]}
                  placeholder="Card title"
                >{@form[:title].value}</textarea>
              </div>
              <p :if={@form[:title].errors != []} class="text-sm text-error">Title can't be blank.</p>
              <div class="flex flex-wrap items-center gap-x-1.5 px-1 text-sm text-base-content/50">
                <span>in list</span>
                <%!-- The quickest way to move a card, and the only practical one
                      on a phone, where dragging it across a board that shows one
                      list at a time is no way to live. The sidebar keeps its own
                      copy of this field; `card_change` touches only what the form
                      it came from carried. --%>
                <select
                  :if={@can_write}
                  name="card[column_id]"
                  class="select select-ghost select-sm w-auto max-w-[12rem] pl-1 font-medium text-base-content/80"
                  title="Move this card to another list"
                  aria-label="List"
                >
                  <option
                    :for={{name, id} <- column_options(@board)}
                    value={id}
                    selected={id == @card.column_id}
                  >
                    {name}
                  </option>
                </select>
                <span :if={!@can_write} class="font-medium text-base-content/80">
                  {@card.column.name}
                </span>
                <%!-- `type="button"` matters: this sits inside the card form. --%>
                <button
                  :if={@can_write}
                  type="button"
                  id="card-move-board"
                  phx-click="open_move_board"
                  phx-target="#board-move"
                  phx-value-id={@card.id}
                  class="link link-hover text-base-content/60 hover:text-primary"
                  title="Move this card to another board, with its subcards"
                >
                  another board…
                </button>
                <span>· created {relative_time(@card.inserted_at)}</span>
              </div>

              <div class="space-y-1.5 px-1 pt-2" data-section-key="f">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <.keyed_label key="f" label="Flags" />
                </p>
                <div class="flex flex-wrap gap-1.5">
                  <.flag_toggle
                    :for={{flag, _, _, _, _} <- flags()}
                    flag={flag}
                    active={flag in @card.flags}
                    phx-click="toggle_flag"
                    phx-value-flag={flag}
                  />
                </div>
              </div>

              <div class="space-y-1.5 px-1" data-section-key="t">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <.keyed_label key="t" label="Tags" />
                </p>
                <div class="flex flex-wrap items-center gap-1.5">
                  <.tag_toggle
                    :for={tag <- @board.tags}
                    tag={tag}
                    active={Enum.any?(@card.tags, &(&1.id == tag.id))}
                    phx-click="toggle_tag"
                    phx-value-id={tag.id}
                  />
                  <.link patch={@tags_path} class="btn btn-ghost btn-xs">
                    <.icon name="hero-plus" class="size-3.5" /> New tag
                  </.link>
                </div>
              </div>

              <div class="space-y-1.5 px-1" data-section-key="d">
                <div class="flex items-center justify-between">
                  <label
                    for="card-description"
                    class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60"
                  >
                    <.icon name="hero-bars-3-bottom-left" class="size-3.5" />
                    <.keyed_label key="d" label="Description" />
                  </label>
                  <button
                    :if={@can_write and not @editing_description and (@card.description || "") != ""}
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="edit_description"
                  >
                    <.icon name="hero-pencil" class="size-3.5" /> Edit
                  </button>
                  <button
                    :if={@editing_description}
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="stop_editing_description"
                  >
                    <.icon name="hero-check" class="size-3.5" /> Done
                  </button>
                </div>
                <div
                  :if={@editing_description}
                  id="card-description-paste"
                  phx-hook="PasteImage"
                  data-upload="desc_image"
                  class="space-y-1"
                >
                  <div
                    id="card-description-mention"
                    phx-hook="Mention"
                    data-people={@mention_people}
                  >
                    <textarea
                      id="card-description"
                      name={@form[:description].name}
                      phx-debounce="700"
                      phx-hook="AutoGrow"
                      phx-keydown="stop_editing_description"
                      phx-key="Escape"
                      autofocus
                      rows="3"
                      placeholder="Add more detail…"
                      class="textarea w-full resize-none text-sm leading-relaxed"
                    >{@form[:description].value}</textarea>
                  </div>
                  <.live_file_input upload={@uploads.desc_image} class="hidden" />
                  <p class="text-2xs text-base-content/60">
                    Paste or drop an image to add it; type @ to mention somebody. Click Done or press Escape when finished.
                  </p>
                </div>
                <div
                  :if={not @editing_description and (@card.description || "") != ""}
                  id="card-description-view"
                  class={[
                    "rounded-lg px-1 py-1 text-sm leading-relaxed whitespace-pre-wrap break-words",
                    @can_write && "cursor-text hover:bg-base-200/60"
                  ]}
                  phx-click={@can_write && "edit_description"}
                  phx-no-format
                >{RichText.render(@card.description, board: @board, as: @current_user)}</div>
                <button
                  :if={not @editing_description and (@card.description || "") == "" and @can_write}
                  type="button"
                  class="w-full rounded-lg bg-base-200/60 px-3 py-2 text-left text-sm text-base-content/50 hover:bg-base-200"
                  phx-click="edit_description"
                >
                  Add more detail…
                </button>
                <p
                  :if={
                    not @editing_description and (@card.description || "") == "" and not @can_write
                  }
                  class="px-1 text-sm italic text-base-content/40"
                >
                  No description.
                </p>
              </div>
            </.form>

            <section
              id="card-attachments"
              class="space-y-2 rounded-xl px-1 transition-colors"
              phx-drop-target={@uploads.attachment.ref}
              data-section-key="a"
            >
              <div class="flex items-center justify-between">
                <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <.icon name="hero-paper-clip" class="size-3.5" />
                  <.keyed_label key="a" label="Attachments" />
                  <span :if={@card.attachments != []} class="font-normal">({length(@card.attachments)})</span>
                </h3>
                <form
                  :if={@can_write}
                  id="attach-form"
                  phx-change="validate_attachments"
                  phx-submit="validate_attachments"
                >
                  <label class="btn btn-ghost btn-xs cursor-pointer">
                    <.icon name="hero-arrow-up-tray" class="size-3.5" /> Attach
                    <.live_file_input upload={@uploads.attachment} class="hidden" />
                  </label>
                </form>
              </div>
              <ul :if={@card.attachments != []} class="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <li
                  :for={a <- @card.attachments}
                  id={"attachment-#{a.id}"}
                  class="group flex items-center gap-3 rounded-xl bg-base-200/70 p-2"
                >
                  <a
                    href={Boards.attachment_url(a)}
                    target="_blank"
                    rel="noopener"
                    class="flex size-12 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-base-300/60"
                    title={a.filename}
                  >
                    <img
                      :if={Attachment.image?(a)}
                      src={Boards.attachment_url(a)}
                      alt={a.filename}
                      loading="lazy"
                      class="size-full object-cover"
                    />
                    <.icon
                      :if={not Attachment.image?(a)}
                      name={attachment_icon(a)}
                      class="size-6 text-base-content/50"
                    />
                  </a>
                  <div class="min-w-0 flex-1">
                    <a
                      href={Boards.attachment_url(a)}
                      target="_blank"
                      rel="noopener"
                      class="block truncate text-sm font-medium hover:underline"
                    >
                      {a.filename}
                    </a>
                    <p class="text-xs text-base-content/50">
                      {human_size(a.size)} · {relative_time(a.inserted_at)}
                    </p>
                  </div>
                  <button
                    :if={@can_write}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square shrink-0 opacity-0 group-hover:opacity-100 focus:opacity-100 no-hover:opacity-100"
                    phx-click="delete_attachment"
                    phx-value-id={a.id}
                    data-confirm={"Delete #{a.filename}?"}
                    title="Delete attachment"
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                </li>
              </ul>
              <div
                :for={entry <- @uploads.attachment.entries}
                id={"upload-#{entry.ref}"}
                class="flex items-center gap-3 rounded-xl bg-base-200/40 px-3 py-2"
              >
                <.icon name="hero-arrow-up-tray" class="size-4 shrink-0 text-base-content/50" />
                <div class="min-w-0 flex-1 space-y-1">
                  <p class="truncate text-xs">{entry.client_name}</p>
                  <progress
                    class="progress progress-primary h-1 w-full"
                    value={entry.progress}
                    max="100"
                  ></progress>
                </div>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs btn-square"
                  phx-click="cancel_upload"
                  phx-value-name="attachment"
                  phx-value-ref={entry.ref}
                  title="Cancel upload"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </div>
              <p
                :if={@card.attachments == [] and @uploads.attachment.entries == [] and @can_write}
                class="text-xs text-base-content/40"
              >
                Drop files here, or paste images straight into the description or a comment.
              </p>
            </section>

            <.checklist_section
              item={@card}
              can_write={@can_write}
              form_key={@form_key}
              section_key="e"
            />
            <section class="space-y-2 px-1" data-section-key="s">
              <div class="flex items-center justify-between">
                <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <.icon name="hero-squares-2x2" class="size-3.5" />
                  <.keyed_label key="s" label="Subcards" />
                </h3>
                <div class="flex items-center gap-1.5">
                  <button
                    :if={@can_write and Board.sprints?(@board)}
                    id="card-sprint-add-cards"
                    type="button"
                    class="btn btn-xs"
                    phx-click="open_sprint_picker"
                    phx-target="#board-sprints"
                    phx-value-id={@card.id}
                    title="Pick cards from your boards to add to this sprint"
                  >
                    <.icon name="hero-queue-list" class="size-3.5" /> Add cards…
                  </button>
                  <.link
                    :if={@card.sub_board}
                    navigate={~p"/boards/#{@card.sub_board.id}"}
                    class="btn btn-xs btn-primary"
                  >
                    Open board <.icon name="hero-arrow-right" class="size-3.5" />
                  </.link>
                </div>
              </div>

              <%= if @card.sub_board do %>
                <div
                  :for={{done, total} <- [Card.progress(@card)]}
                  class="flex items-center gap-2 text-xs text-base-content/60"
                >
                  <progress
                    class={[
                      "progress h-1.5 flex-1",
                      if(total > 0 and done == total,
                        do: "progress-success",
                        else: "progress-primary"
                      )
                    ]}
                    value={done}
                    max={max(total, 1)}
                  ></progress>
                  <span>{done}/{total} done</span>
                  <span
                    :if={@card.rollup && @card.rollup.depth > 1}
                    title="Counting every level beneath this card"
                  >
                    · {@card.rollup.depth} levels
                  </span>
                  <.health_pill health={Card.health(@card)} />
                </div>
                <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
                  <div :for={col <- @card.sub_board.columns} class="rounded-xl bg-base-200/60 p-2">
                    <p class="mb-1 flex items-center gap-1.5 px-1 text-xs font-semibold">
                      <span :if={col.color} class={["size-2 rounded-full", Palette.dot(col.color)]}></span>
                      {col.name}
                      <span class="ml-auto font-mono text-2xs text-base-content/50">{Enum.count(
                        @card.sub_board.cards,
                        &(&1.column_id == col.id)
                      )}</span>
                    </p>
                    <ul class="space-y-0.5">
                      <li
                        :for={sub <- Enum.filter(@card.sub_board.cards, &(&1.column_id == col.id))}
                        id={"subcard-#{sub.id}"}
                        class="flex items-center gap-1.5 rounded px-1 py-0.5 text-sm hover:bg-base-100/60"
                      >
                        <button
                          type="button"
                          phx-click="toggle_subcard"
                          phx-value-id={sub.id}
                          class={
                            if(sub.completed,
                              do: "text-success",
                              else: "text-base-content/30 hover:text-success"
                            )
                          }
                          title="Toggle complete"
                        >
                          <.icon
                            name={
                              if sub.completed,
                                do: "hero-check-circle-solid",
                                else: "hero-check-circle"
                            }
                            class="size-4"
                          />
                        </button>
                        <.link
                          navigate={~p"/boards/#{@card.sub_board.id}/cards/#{sub.id}"}
                          class={[
                            "truncate hover:underline",
                            sub.completed && "text-base-content/50"
                          ]}
                        >
                          {sub.title}
                        </.link>
                      </li>
                    </ul>
                    <form
                      id={"add-subcard-#{col.id}-#{@form_key}"}
                      phx-submit="quick_add_subcard"
                      class="mt-1"
                    >
                      <input type="hidden" name="column_id" value={col.id} />
                      <input
                        type="text"
                        name="title"
                        placeholder="Add a subcard…"
                        class="input input-xs w-full"
                        autocomplete="off"
                        required
                      />
                    </form>
                  </div>
                </div>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_sub_board"
                  data-confirm="Remove all subcards of this card? This deletes them permanently."
                >
                  <.icon name="hero-trash" class="size-3.5" /> Remove subcards
                </button>
              <% else %>
                <p class="text-xs text-base-content/50">
                  Turn this card into a board of its own. Pick a template for its lists.
                </p>
                <button
                  :if={!@picking_template}
                  type="button"
                  class="btn btn-sm"
                  phx-click="pick_template"
                >
                  <.icon name="hero-squares-plus" class="size-4" /> Add subcards
                </button>
                <div
                  :if={@picking_template}
                  class="kanban-pop space-y-1 rounded-xl bg-base-200/60 p-2"
                >
                  <button
                    :for={t <- @templates}
                    type="button"
                    class="flex w-full items-start gap-2 rounded-lg px-2 py-1.5 text-left hover:bg-base-100"
                    phx-click="create_sub_board"
                    phx-value-template={t.id}
                  >
                    <.icon name="hero-view-columns" class="mt-0.5 size-4 shrink-0 text-primary" />
                    <span class="min-w-0">
                      <span class="block text-sm font-medium">{t.name}</span>
                      <span class="block truncate text-xs text-base-content/50">{Enum.map_join(
                        t.columns,
                        " · ",
                        & &1["name"]
                      )}</span>
                    </span>
                  </button>
                  <p :if={@templates == []} class="px-2 text-xs text-base-content/50">
                    No templates yet.
                  </p>
                  <div class="flex items-center justify-between px-1 pt-1">
                    <.link navigate={~p"/templates"} class="text-xs text-primary hover:underline">Manage templates</.link>
                    <button type="button" class="btn btn-ghost btn-xs" phx-click="pick_template">Cancel</button>
                  </div>
                </div>
              <% end %>
            </section>

            <section :if={not @board.simple} class="space-y-2 px-1" data-section-key="p">
              <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                <.icon name="hero-link" class="size-3.5" />
                <.keyed_label key="p" label="Dependencies" />
              </h3>
              <div
                :for={
                  {label, cards, icon} <- [
                    {"Blocked by", @card.blocked_by, "hero-lock-closed"},
                    {"Blocks", @card.blocks, "hero-arrow-right-circle"}
                  ]
                }
                :if={cards != []}
                class="space-y-1"
              >
                <p class="text-xs text-base-content/60">{label}</p>
                <ul class="space-y-1">
                  <li
                    :for={dep <- cards}
                    id={"dep-#{label == "Blocks" && "blocks" || "by"}-#{dep.id}"}
                    class="group flex items-center gap-2 rounded-lg px-1 py-1 hover:bg-base-200/60"
                  >
                    <.icon
                      name={if dep.completed, do: "hero-check-circle-solid", else: icon}
                      class={[
                        "size-4 shrink-0",
                        if(dep.completed, do: "text-success", else: "text-error")
                      ]}
                    />
                    <.link
                      patch={@card_link.(dep.id)}
                      class={[
                        "min-w-0 flex-1 truncate text-sm hover:underline",
                        dep.completed && "text-base-content/50"
                      ]}
                    >
                      {dep.title}
                    </.link>
                    <span :if={dep.archived_at} class="badge badge-ghost badge-xs">archived</span>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs btn-square opacity-0 group-hover:opacity-100 no-hover:opacity-100"
                      phx-click="remove_dependency"
                      phx-value-id={dep.id}
                      title="Remove dependency"
                    >
                      <.icon name="hero-x-mark" class="size-3.5" />
                    </button>
                  </li>
                </ul>
              </div>
              <form
                id={"dep-search-#{@form_key}"}
                phx-change="dep_search"
                phx-submit="dep_search"
                class="space-y-1.5"
              >
                <div class="flex items-center gap-1">
                  <div class="join">
                    <button
                      :for={{value, label} <- [{"blocked_by", "Blocked by"}, {"blocks", "Blocks"}]}
                      type="button"
                      class={[
                        "btn btn-xs join-item",
                        if(@dep_direction == value, do: "btn-neutral", else: "btn-ghost")
                      ]}
                      phx-click="dep_direction"
                      phx-value-direction={value}
                    >
                      {label}
                    </button>
                  </div>
                  <input
                    type="search"
                    name="q"
                    value={@dep_query}
                    placeholder={
                      if @dep_direction == "blocked_by",
                        do: "Find the card this one waits for…",
                        else: "Find the card this one holds up…"
                    }
                    class="input input-sm flex-1"
                    phx-debounce="200"
                    autocomplete="off"
                  />
                </div>
                <ul :if={@dep_results != []} class="menu menu-sm rounded-xl bg-base-200/70 p-1">
                  <li :for={result <- @dep_results}>
                    <button type="button" phx-click="add_dependency" phx-value-id={result.id}>
                      <.icon name="hero-plus" class="size-3.5" />
                      <span class={result.completed && "opacity-60"}>{result.title}</span>
                      <span class="ml-auto text-xs opacity-50">{column_name(@board, result.column_id)}</span>
                    </button>
                  </li>
                </ul>
                <p
                  :if={@dep_query != "" and @dep_results == []}
                  class="px-1 text-xs text-base-content/50"
                >
                  No other cards match.
                </p>
              </form>
            </section>

            <%!-- Docs: the wiki pages that talk about this card. A pinned page
                  is *the* spec, runbook or retro for it, which is a person's
                  judgement rather than something the prose says — so it leads,
                  and it survives whoever next edits the page. --%>
            <section class="space-y-2 px-1" id="card-docs" data-section-key="o">
              <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                <.icon name="hero-document-text" class="size-3.5" />
                <.keyed_label key="o" label="Docs" />
              </h3>
              <ul :if={@pages != []} class="space-y-1">
                <li
                  :for={link <- @pages}
                  id={"card-doc-#{link.id}"}
                  class="group flex items-center gap-2 text-sm"
                >
                  <.icon
                    name={if link.pinned, do: "hero-bookmark-solid", else: "hero-document-text"}
                    class={[
                      "size-4 shrink-0",
                      if(link.pinned, do: "text-primary", else: "text-base-content/40")
                    ]}
                  />
                  <.link
                    navigate={~p"/boards/#{link.page.board_id}/wiki/#{link.page.slug}"}
                    class="min-w-0 flex-1 truncate hover:underline"
                    title={link.page.summary || link.page.title}
                  >
                    {link.page.title}
                  </.link>
                  <span class="shrink-0 font-mono text-2xs text-base-content/40">{link.page.code}</span>
                  <button
                    :if={@can_write}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="toggle_pin_doc"
                    phx-value-page={link.page.id}
                    title={
                      if link.pinned, do: "Unpin this doc", else: "Pin: this is the doc for this card"
                    }
                  >
                    <.icon
                      name={if link.pinned, do: "hero-bookmark-slash", else: "hero-bookmark"}
                      class="size-3.5"
                    />
                  </button>
                  <%!-- Only a link the prose does not make can be taken off
                        here: a page that really names this card keeps saying
                        so (see `Slipdock.Wiki.Links.unlink/2`). --%>
                  <button
                    :if={@can_write and link.count == 0}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="detach_doc"
                    phx-value-page={link.page.id}
                    title="Detach this doc"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </li>
              </ul>
              <p :if={@pages == []} class="text-xs text-base-content/50">
                Nothing written about this card yet.
              </p>
              <div :if={@can_write} class="flex flex-wrap items-center gap-1">
                <button type="button" class="btn btn-ghost btn-xs gap-1" phx-click="write_up">
                  <.icon name="hero-pencil-square" class="size-3.5" /> Write it up
                </button>
                <.link navigate={~p"/boards/#{@board}/wiki"} class="btn btn-ghost btn-xs">
                  Open the wiki
                </.link>
              </div>
              <%!-- Most of the time the document already exists and what is
                    missing is the link to it. --%>
              <form
                :if={@can_write}
                id="card-doc-search"
                phx-change="doc_search"
                phx-submit="doc_search"
                class="relative"
              >
                <.icon
                  name="hero-magnifying-glass"
                  class="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-base-content/40"
                />
                <input
                  type="search"
                  name="q"
                  value={@doc_query}
                  placeholder="Attach a page already written…"
                  phx-debounce="200"
                  autocomplete="off"
                  class="input input-xs w-full rounded-full pl-7"
                />
              </form>
              <ul :if={@doc_results != []} class="space-y-0.5">
                <li :for={page <- @doc_results}>
                  <button
                    type="button"
                    phx-click="attach_doc"
                    phx-value-page={page.id}
                    class="flex w-full items-center gap-1.5 rounded-lg px-1.5 py-1 text-left text-xs hover:bg-base-200"
                  >
                    <.icon name="hero-plus" class="size-3 shrink-0 text-base-content/40" />
                    <span class="min-w-0 flex-1 truncate">{page.title}</span>
                    <span class="shrink-0 font-mono text-2xs text-base-content/40">{page.code}</span>
                  </button>
                </li>
              </ul>
            </section>

            <section class="space-y-2 px-1" id="card-links" data-section-key="n">
              <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                <.icon name="hero-arrows-right-left" class="size-3.5" />
                <.keyed_label key="n" label="Links" />
              </h3>
              <ul :if={@card.links_out != [] or @card.links_in != []} class="space-y-1">
                <li
                  :for={
                    {link, other, dir} <-
                      Enum.map(@card.links_out, &{&1, &1.to, :out}) ++
                        Enum.map(@card.links_in, &{&1, &1.from, :in})
                  }
                  id={"link-#{link.id}"}
                  class="flex items-center gap-2 text-xs"
                >
                  <span class="chip chip-line shrink-0 text-2xs">{CardLink.label(link.kind, dir)}</span>
                  <.link
                    navigate={~p"/boards/#{other.board_id}/cards/#{other.id}"}
                    class={[
                      "min-w-0 flex-1 truncate hover:underline",
                      other.completed && "text-base-content/60"
                    ]}
                    title={other.title}
                  >
                    {other.title}
                  </.link>
                  <span
                    :if={other.board_id != @board.id and match?(%{name: _}, other.board)}
                    class="max-w-32 shrink-0 truncate text-2xs text-base-content/50"
                    title={"On board #{other.board.name}"}
                  >
                    {other.board.name}
                  </span>
                  <button
                    :if={@can_write}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="remove_link"
                    phx-value-id={link.id}
                    title="Remove link"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </li>
              </ul>
              <.contributions_bar card={@card} />
              <form
                :if={@can_write}
                id={"link-form-#{@form_key}"}
                phx-change="link_search"
                phx-submit="link_search"
                class="space-y-1.5"
              >
                <div class="flex gap-1">
                  <select name="kind" class="select select-xs w-36" title="Kind of link">
                    <option
                      :for={{key, label, _} <- CardLink.kinds()}
                      value={key}
                      selected={key == @link_kind}
                    >
                      {label}
                    </option>
                  </select>
                  <input
                    type="search"
                    name="q"
                    value={@link_query}
                    placeholder="Search cards on any board…"
                    class="input input-xs min-w-0 flex-1"
                    autocomplete="off"
                    phx-debounce="250"
                  />
                </div>
                <ul :if={@link_results != []} class="menu menu-sm rounded-xl bg-base-200/70 p-1">
                  <li :for={result <- @link_results}>
                    <button
                      type="button"
                      phx-click="add_link"
                      phx-value-id={result.id}
                      class="flex items-center gap-2"
                    >
                      <span class="truncate">{result.title}</span>
                      <span class="ml-auto shrink-0 text-2xs text-base-content/50">{result.board.name}</span>
                    </button>
                  </li>
                </ul>
                <p
                  :if={@link_query != "" and @link_results == []}
                  class="px-1 text-xs text-base-content/50"
                >
                  No cards match.
                </p>
              </form>
            </section>

            <.urls_section
              item={@card}
              can_write={@can_write}
              form_key={@form_key}
              section_key="w"
            />

            <.comments_section
              item={@card}
              board={@board}
              current_user={@current_user}
              can_write={@can_write}
              form_key={@form_key}
              uploads={@uploads}
              mention_people={@mention_people}
              section_key="c"
            />
          </div>

          <aside class="min-w-0 space-y-5 rounded-b-2xl bg-base-200/60 p-5 md:rounded-r-2xl md:rounded-bl-none">
            <.form for={@form} id="card-meta-form" phx-change="card_change" class="space-y-4">
              <label class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">List</span>
                <select name="card[column_id]" class="select select-sm w-full">
                  <option
                    :for={{name, id} <- column_options(@board)}
                    value={id}
                    selected={id == @card.column_id}
                  >
                    {name}
                  </option>
                </select>
              </label>
              <div class="space-y-1" id="card-assignees">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Assignees
                </span>
                <ul :if={Card.assignees(@card) != []} class="flex flex-wrap gap-1">
                  <li
                    :for={u <- Card.assignees(@card)}
                    id={"card-assignee-#{u.id}"}
                    class="inline-flex items-center gap-1 rounded-full bg-base-200 py-0.5 pr-1 pl-0.5"
                  >
                    <.assignee_chip user={u} size="xs" with_name />
                    <button
                      type="button"
                      phx-click="remove_assignee"
                      phx-value-id={u.id}
                      class="rounded-full p-0.5 text-base-content/50 transition hover:bg-base-300 hover:text-base-content"
                      title={"Unassign #{Slipdock.Accounts.User.display_name(u)}"}
                    >
                      <.icon name="hero-x-mark" class="size-3" />
                    </button>
                  </li>
                </ul>
                <%!-- Keyed on who is already on the card, so the picker comes back
                     empty after each pick instead of re-sending the last one. --%>
                <select
                  name="card[add_assignee_id]"
                  class="select select-sm w-full"
                  id={"card-assignee-add-" <> Enum.map_join(Card.assignees(@card), "-", & &1.id)}
                >
                  <option value="" selected>
                    {if Card.assignees(@card) == [],
                      do: "Unassigned — add someone…",
                      else: "Add someone…"}
                  </option>
                  <option
                    :for={u <- @users}
                    :if={not Card.assigned_to?(@card, u.id)}
                    value={u.id}
                  >
                    {Slipdock.Accounts.User.display_name(u)}
                  </option>
                </select>
              </div>
              <label class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Priority</span>
                <select name="card[priority]" class="select select-sm w-full">
                  <option
                    :for={{label, value} <- priority_options()}
                    value={value}
                    selected={value == @card.priority}
                  >
                    {label}
                  </option>
                </select>
              </label>
              <%!-- A simple board is a to-do list: what follows down to Health,
                    bar the due date and Completed, is project tracking, and
                    stays out of its way (`Board.simple?/1`). --%>
              <label :if={not @board.simple} class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">% complete</span>
                <div class="flex items-center gap-2">
                  <input
                    type="number"
                    name="card[percent_complete]"
                    id="card-percent-complete"
                    value={@card.percent_complete}
                    min="0"
                    max="100"
                    step="5"
                    placeholder="—"
                    phx-debounce="400"
                    class="input input-sm w-20"
                  />
                  <progress
                    :if={@card.percent_complete}
                    class={[
                      "progress h-1.5 flex-1",
                      if(@card.percent_complete == 100,
                        do: "progress-success",
                        else: "progress-primary"
                      )
                    ]}
                    value={@card.percent_complete}
                    max="100"
                  ></progress>
                </div>
                <p :if={@form[:percent_complete].errors != []} class="text-xs text-error">
                  Use a whole number from 0 to 100.
                </p>
              </label>
              <label :if={not @board.simple} class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Start date</span>
                <input
                  type="date"
                  name="card[start_date]"
                  value={@card.start_date}
                  max={@card.due_date}
                  class="input input-sm w-full"
                />
              </label>
              <label class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Due date</span>
                <input
                  type="date"
                  name="card[due_date]"
                  value={@card.due_date}
                  min={@card.start_date}
                  class="input input-sm w-full"
                />
                <.due_badge date={@card.due_date} completed={@card.completed} />
                <p :if={@form[:start_date].errors != []} class="text-xs text-error">
                  Start must be on or before the due date.
                </p>
              </label>
              <label :if={not @board.simple} class="block space-y-1">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Precision</span>
                <select
                  name="card[date_precision]"
                  class="select select-sm w-full"
                  id="card-precision"
                >
                  <option
                    :for={{key, label} <- Dates.precisions()}
                    value={key}
                    selected={key == (@card.date_precision || "day")}
                  >
                    {label}
                  </option>
                </select>
                <p :if={Card.fuzzy?(@card) and @card.due_date} class="text-xs text-base-content/60">
                  Scheduled for {Dates.range_label(
                    @card.start_date || @card.due_date,
                    @card.due_date,
                    @card.date_precision
                  )}
                </p>
              </label>
              <div
                :if={
                  (not @board.simple and @card.rollup) && @card.rollup.children > 0 &&
                    @card.rollup.derived_due
                }
                class="space-y-1 rounded-lg bg-base-200/60 p-2 text-xs"
                id="card-rollup-dates"
              >
                <p class="flex items-center gap-1 font-semibold uppercase tracking-wide text-base-content/60">
                  <.icon name="hero-arrow-up-on-square-stack" class="size-3.5" /> From subcards
                </p>
                <p class="text-base-content/80">
                  {fmt_date(@card.rollup.derived_start)} → {fmt_date(@card.rollup.derived_due)}
                </p>
                <p
                  :if={@card.rollup.start_slip > 0}
                  class="flex items-center gap-1 text-warning-content dark:text-warning"
                >
                  <.icon name="hero-arrow-trending-up" class="size-3.5" />
                  {past_date_label(:start, @card.rollup.start_slip)}
                  <span class="text-base-content/50">(yours: {fmt_date(@card.start_date)})</span>
                </p>
                <p
                  :if={@card.rollup.due_slip > 0}
                  class="flex items-center gap-1 text-warning-content dark:text-warning"
                >
                  <.icon name="hero-arrow-trending-up" class="size-3.5" />
                  {past_date_label(:due, @card.rollup.due_slip)}
                  <span class="text-base-content/50">(yours: {fmt_date(@card.due_date)})</span>
                </p>
                <p :if={is_nil(@card.due_date)} class="text-base-content/50">
                  No due date of its own, so the subcards set it.
                </p>
              </div>
              <p
                :if={Card.days_past_due(@card) > 0}
                class="flex items-center gap-1 rounded-lg bg-error/10 p-2 text-xs text-error"
                id="card-past-due"
              >
                <.icon name="hero-exclamation-triangle" class="size-3.5" />
                This card is {past_date_label(:due, Card.days_past_due(@card))}
              </p>
              <label class="flex cursor-pointer items-center justify-between">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Completed</span>
                <input type="hidden" name="card[completed]" value="false" />
                <input
                  type="checkbox"
                  name="card[completed]"
                  value="true"
                  class="toggle toggle-success toggle-sm"
                  checked={@card.completed}
                />
              </label>
              <div :if={not @board.simple} class="space-y-1.5" id="card-status">
                <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Health</span>
                <div class="flex flex-wrap items-center gap-1.5">
                  <.health_pill health={Card.health(@card)} />
                  <.stated_pill
                    :if={Card.stated_health(@card)}
                    health={Card.stated_health(@card)}
                    title="Reported by the card's owner"
                  />
                </div>
                <p class="text-xs text-base-content/50">
                  The first pill is computed from dates, blockers and subcards; the second is
                  what was last reported.
                </p>
              </div>
            </.form>
            <.time_section
              :if={not @board.simple}
              card={@card}
              can_write={@can_write}
              form_key={@form_key}
            />
            <.status_section
              :if={not @board.simple}
              item={@card}
              can_write={@can_write}
              form_key={@form_key}
              stated={Card.stated_health(@card)}
            />
            <.fields_section item={@card} board={@board} can_write={@can_write} />
            <.vote_box
              :if={not @board.simple}
              item={@card}
              board={@board}
              current_user={@current_user}
              can_write={@can_write}
            />

            <div class="space-y-1.5">
              <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Cover</span>
              <div class="flex flex-wrap gap-1.5">
                <button
                  type="button"
                  class={[
                    "flex size-6 items-center justify-center rounded-full ring-1 ring-base-content/20 ring-offset-2 ring-offset-base-100",
                    is_nil(@card.color) && "ring-2 ring-base-content"
                  ]}
                  phx-click="set_cover"
                  phx-value-color=""
                  title="No cover"
                >
                  <.icon name="hero-no-symbol" class="size-3.5 opacity-50" />
                </button>
                <.color_swatch
                  :for={{name, _} <- Palette.all()}
                  color={name}
                  selected={@card.color == name}
                  phx-click="set_cover"
                  phx-value-color={name}
                />
              </div>
            </div>

            <div class="space-y-1.5 border-t border-base-content/10 pt-4">
              <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Actions</span>
              <button type="button" class="btn btn-sm w-full justify-start" phx-click="archive_card">
                <.icon name="hero-archive-box" class="size-4" /> Archive
              </button>
              <button
                type="button"
                class="btn btn-ghost btn-sm w-full justify-start text-error"
                phx-click="delete_card"
                data-confirm="Delete this card permanently?"
              >
                <.icon name="hero-trash" class="size-4" /> Delete
              </button>
            </div>
          </aside>
        </div>
      </fieldset>
      <div :if={@can_share} class="border-t border-base-content/10 px-6 py-4">
        <p class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Sharing this card
        </p>
        <.share_panel
          resource="card"
          grants={@grants}
          groups={@groups}
          can_manage={@can_share}
          form_key={@share_key}
          compact
        />
      </div>
      <.live_component
        :if={@ai?}
        module={SlipdockWeb.AIChatComponent}
        id={"card-ai-#{@card.id}"}
        layout="inline"
        title="Ask AI about this card"
        placeholder="Ask about this card…"
        source={%{kind: :card, board: @board, card: @card, users: @users}}
        current_user={@current_user}
        can_write={@can_write}
      />
    </.modal>
    """
  end

  attr :board, :any, required: true
  attr :activities, :list, required: true
  attr :close_path, :string, required: true

  defp activity_modal(assigns) do
    ~H"""
    <.modal id="activity-modal" on_close={JS.patch(@close_path)} size="md">
      <div class="space-y-4 p-6">
        <h2 class="flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-bolt" class="size-5 text-warning" /> Activity
        </h2>
        <p :if={@activities == []} class="text-sm text-base-content/60">Nothing has happened yet.</p>
        <ol class="max-h-[60vh] space-y-1 overflow-y-auto kanban-scroll pr-1">
          <li
            :for={a <- @activities}
            id={"activity-#{a.id}"}
            class="flex items-start gap-3 rounded-lg px-2 py-1.5 hover:bg-base-200/60"
          >
            <span class="mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full bg-base-200 text-base-content/60">
              <.icon name={activity_icon(a.kind)} class="size-3.5" />
            </span>
            <div class="min-w-0 flex-1">
              <p class="text-sm">{a.message}</p>
              <p class="text-xs text-base-content/50">{relative_time(a.inserted_at)}</p>
            </div>
          </li>
        </ol>
      </div>
    </.modal>
    """
  end

  attr :board, :any, required: true
  attr :archived, :list, required: true
  attr :close_path, :string, required: true

  defp archive_modal(assigns) do
    ~H"""
    <.modal id="archive-modal" on_close={JS.patch(@close_path)} size="md">
      <div class="space-y-4 p-6">
        <h2 class="flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-archive-box" class="size-5" /> Archived cards
        </h2>
        <p :if={@archived == []} class="text-sm text-base-content/60">No archived cards.</p>
        <ul class="max-h-[60vh] space-y-2 overflow-y-auto kanban-scroll pr-1">
          <li
            :for={card <- @archived}
            id={"archived-#{card.id}"}
            class="flex items-center gap-3 rounded-xl bg-base-200/60 px-3 py-2"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium">{card.title}</p>
              <p class="text-xs text-base-content/50">
                from {card.column.name} · archived {relative_time(card.archived_at)}
              </p>
              <div :if={card.tags != []} class="mt-1 flex flex-wrap gap-1">
                <.tag_chip :for={tag <- card.tags} tag={tag} size="xs" />
              </div>
            </div>
            <button type="button" class="btn btn-sm" phx-click="restore_card" phx-value-id={card.id}>
              <.icon name="hero-arrow-uturn-left" class="size-4" /> Restore
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-square text-error"
              phx-click="delete_archived"
              phx-value-id={card.id}
              data-confirm="Delete this card permanently?"
              title="Delete"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </li>
        </ul>
      </div>
    </.modal>
    """
  end

  # A link says what it points at: a page, a file somewhere, an address.
end

defmodule SlipdockWeb.BoardLive.Index do
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents

  import SlipdockWeb.SprintPlanComponents,
    only: [sources_fields: 1, parse_sources: 2, chosen_from: 1]

  alias Slipdock.{Access, Accounts, Boards, Sprints}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Multiboard.Saved, as: SavedMultiboard
  alias Slipdock.Palette
  alias Slipdock.Vaults.Vault

  # What the sort control offers, in the order it offers it.
  @sorts [
    {"manual", "My order"},
    {"name", "Name"},
    {"active", "Recently active"},
    {"newest", "Newest first"},
    {"oldest", "Oldest first"},
    {"cards", "Most cards"}
  ]

  # What the custom lists box starts with, to be edited rather than typed out.
  @default_lists "Backlog\nTo Do\nIn Progress\nDone"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Boards.subscribe_templates()

    user = socket.assigns.current_user

    {:ok,
     socket
     |> SlipdockWeb.BoardNotices.subscribe()
     |> assign(page_title: "Boards", creating: false, new_color: "indigo", template_id: nil)
     |> assign(auto_code: "", source_choices: nil, sources_chosen: %{})
     |> assign(custom_lists: @default_lists, save_template: false, template_name: "")
     |> assign(board_layout: user.board_layout || "grid", sort: user.board_sort || "manual")
     |> assign(show_archived: false)
     |> assign(templates: Boards.list_templates(user))
     |> assign(:form, to_form(Boards.change_board(%Board{})))
     |> assign(reordering: false)
     |> load_boards()}
  end

  # Your saved multiboards (#1482), keyed by id: each with how many of its
  # lists you can still read and the boards they are on, in your board order.
  defp multiboard_entries(user, readable) do
    saved = Slipdock.Multiboard.list_saved(user)
    ids = saved |> Enum.flat_map(& &1.lists) |> Enum.uniq()

    board_of = Slipdock.Multiboard.boards_of(ids)

    readable = Map.new(readable, &{&1.id, &1})

    for m <- saved, into: %{} do
      lists = Enum.filter(m.lists, &Map.has_key?(readable, board_of[&1]))
      board_ids = lists |> Enum.map(&board_of[&1]) |> MapSet.new()

      {m.id,
       %{
         multiboard: m,
         lists: length(lists),
         boards:
           for(b <- Map.values(readable), b.id in board_ids, do: b) |> Enum.sort_by(& &1.name)
       }}
    end
  end

  # A sprint template asks which boards its sprints are planned from; the
  # choices are read once, when it is first picked.
  defp put_sources(socket, params) do
    if sprint_template?(socket.assigns.templates, params["template"]) do
      choices =
        socket.assigns.source_choices ||
          Sprints.source_choices(socket.assigns.current_user)

      assign(socket,
        source_choices: choices,
        sources_chosen: chosen_from(parse_sources(params["sources"], choices))
      )
    else
      assign(socket, sources_chosen: %{})
    end
  end

  # "Custom lists" in the Lists menu: the lists are typed one per line, and
  # may be kept as a template under a name of their own (the board's when
  # left blank).
  defp custom_opts(%{"template" => "custom"} = params) do
    columns = String.split(params["lists"] || "", "\n")

    save =
      if params["save_template"] == "true" do
        case String.trim(params["template_name"] || "") do
          "" -> true
          name -> name
        end
      end

    [columns: columns, save_template: save]
  end

  defp custom_opts(_), do: []

  # The box only exists while "Custom lists" is picked, so a change that does
  # not carry it leaves what was typed alone.
  defp put_custom(socket, params) do
    assign(socket,
      custom_lists: params["lists"] || socket.assigns.custom_lists,
      save_template: params["save_template"] == "true",
      template_name: params["template_name"] || socket.assigns.template_name
    )
  end

  defp errors_on(form, field),
    do: form.errors |> Keyword.get_values(field) |> Enum.map(&translate_error/1)

  defp sprint_template?(templates, id),
    do: Enum.any?(templates, &(to_string(&1.id) == id and &1.kind == "sprints"))

  defp load_boards(socket) do
    %{current_user: user, sort: sort} = socket.assigns

    boards = Access.list_boards(user, activity: true, wiki: false)
    multiboards = multiboard_entries(user, boards)

    assign(socket,
      boards: boards,
      multiboards: multiboards,
      # Boards and saved multiboards in the one sequence, in the reader's
      # order. The wiki is the Wiki link's, not a tile (W-2201).
      tiles:
        Boards.sort_boards(
          boards ++ Enum.map(Map.values(multiboards), & &1.multiboard),
          sort
        ),
      archived:
        user
        |> Access.list_boards(archived: true, activity: true, wiki: false)
        |> Boards.sort_boards(sort),
      shared_cards: Access.shared_cards(user),
      # An admin's support sessions, each with the boards it opens: nothing
      # else lists somebody else's boards, so this is the way in.
      supported: Access.supported_boards(user),
      # The reader's own Ctrl+Shift digits, by board id, and by
      # `{:vault, id}` for a vault (#1204).
      hotkeys:
        Map.new(Slipdock.Hotkeys.list(user), fn
          {digit, %Vault{id: id}} -> {{:vault, id}, digit}
          {digit, board} -> {board.id, digit}
        end)
    )
  end

  @impl true
  def handle_info({:boards_changed}, socket) do
    Boards.drain_boards_changed()
    socket = SlipdockWeb.BoardNotices.resubscribe(socket)
    {:noreply, load_boards(socket)}
  end

  def handle_info({:templates_changed}, socket),
    do: {:noreply, assign(socket, templates: Boards.list_templates(socket.assigns.current_user))}

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_create", _, socket) do
    {:noreply,
     assign(socket,
       creating: true,
       auto_code: "",
       custom_lists: @default_lists,
       save_template: false,
       template_name: "",
       form: to_form(Boards.change_board(%Board{}))
     )}
  end

  def handle_event("cancel_create", _, socket), do: {:noreply, assign(socket, creating: false)}

  def handle_event("pick_color", %{"color" => color}, socket) do
    {:noreply, assign(socket, new_color: color)}
  end

  def handle_event("validate", %{"board" => params} = all, socket) do
    {params, auto_code} = sync_code(params, socket.assigns.auto_code)
    form = %Board{} |> Boards.change_board(params) |> Map.put(:action, :validate) |> to_form()

    {:noreply,
     socket
     |> assign(form: form, template_id: all["template"], auto_code: auto_code)
     |> put_custom(all)
     |> put_sources(all)}
  end

  def handle_event("create", %{"board" => params} = all, socket) do
    template =
      case all["template"] do
        id when id in [nil, "", "custom"] -> nil
        id -> Enum.find(socket.assigns.templates, &(to_string(&1.id) == id))
      end

    params = Map.put(params, "color", socket.assigns.new_color)

    case Boards.create_board(
           params,
           [template: template, owner_id: socket.assigns.current_user.id] ++ custom_opts(all)
         ) do
      {:ok, board} ->
        sources = parse_sources(all["sources"], socket.assigns.source_choices || [])

        socket =
          case sources != [] && Sprints.put_sources(board, socket.assigns.current_user, sources) do
            {:error, message} -> put_flash(socket, :error, message)
            _ -> socket
          end

        {:noreply, push_navigate(socket, to: ~p"/boards/#{board}")}

      {:error, changeset} ->
        {:noreply, socket |> assign(form: to_form(changeset)) |> put_custom(all)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with_owned_board(socket, id, fn board ->
      Boards.delete_board(board)
      load_boards(socket)
    end)
  end

  ## The reader's own view of the index ----------------------------------------

  def handle_event("set_layout", %{"layout" => layout}, socket) do
    {:noreply, save_view(socket, %{"board_layout" => layout})}
  end

  def handle_event("set_sort", %{"sort" => sort}, socket) do
    socket = socket |> save_view(%{"board_sort" => sort}) |> load_boards()

    {:noreply,
     assign(socket, reordering: socket.assigns.reordering and socket.assigns.sort == "manual")}
  end

  # Only the admin holding it may end it from here; the Users page ends anybody's.
  def handle_event("end_support", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Accounts.get_support_session(SlipdockWeb.Params.id(id)) do
      %{admin_id: admin_id} = session when admin_id == user.id ->
        {:ok, _} = Accounts.end_support_session(session)
        {:noreply, socket |> put_flash(:info, "Support access ended.") |> load_boards()}

      _ ->
        {:noreply, load_boards(socket)}
    end
  end

  def handle_event("toggle_archived", _, socket) do
    {:noreply, update(socket, :show_archived, &(not &1))}
  end

  ## Archiving and ordering ----------------------------------------------------

  def handle_event("archive", %{"id" => id}, socket) do
    with_owned_board(socket, id, fn board ->
      case Boards.archive_board(board) do
        {:ok, board} ->
          socket
          |> load_boards()
          |> put_flash(:info, "“#{board.name}” archived. Nothing on it was lost.")

        {:error, :sub_board} ->
          put_flash(socket, :error, "Subcard boards go away with their card.")
      end
    end)
  end

  def handle_event("unarchive", %{"id" => id}, socket) do
    with_owned_board(socket, id, fn board ->
      case Boards.unarchive_board(board) do
        {:ok, board} ->
          socket |> load_boards() |> put_flash(:info, "“#{board.name}” is back on your boards.")

        {:error, refused} ->
          put_flash(socket, :error, Slipdock.Quota.refusal_message(refused))
      end
    end)
  end

  # A drag in the compact list: the board lands in front of `before`, or at the
  # end when it was dropped last.
  def handle_event("reorder", %{"id" => id, "before" => before}, socket) do
    case find_tile(socket, id) do
      nil ->
        {:noreply, socket}

      tile ->
        Boards.place_board(socket.assigns.current_user, tile, before, socket.assigns.tiles)
        {:noreply, load_boards(socket)}
    end
  end

  # Reorder mode (#1485): every tile is its own drag handle, with its links
  # and menus out of the way. Only "My order" can be rearranged, so entering
  # it switches to that sort, and saves it the way the sort control does.
  def handle_event("toggle_reorder", _, socket) do
    if socket.assigns.reordering do
      {:noreply, assign(socket, reordering: false)}
    else
      socket =
        if socket.assigns.sort == "manual",
          do: socket,
          else: socket |> save_view(%{"board_sort" => "manual"}) |> load_boards()

      {:noreply, assign(socket, reordering: true, creating: false)}
    end
  end

  def handle_event("exit_reorder", _, socket), do: {:noreply, assign(socket, reordering: false)}

  # The same move without a mouse, from the board's own menu.
  def handle_event("nudge", %{"id" => id, "dir" => dir}, socket) do
    direction = if dir == "up", do: :up, else: :down

    case find_tile(socket, id) do
      nil ->
        {:noreply, socket}

      tile ->
        Boards.nudge_board(socket.assigns.current_user, tile, direction, socket.assigns.tiles)
        {:noreply, load_boards(socket)}
    end
  end

  # A saved multiboard's colour and its deletion, from its own menu (#1482).
  def handle_event("multiboard_color", %{"id" => id, "color" => color}, socket) do
    with %SavedMultiboard{} = m <- find_tile(socket, "multiboard-" <> id) do
      Slipdock.Multiboard.update_saved(m, %{"color" => color})
    end

    {:noreply, load_boards(socket)}
  end

  def handle_event("delete_multiboard", %{"id" => id}, socket) do
    case find_tile(socket, "multiboard-" <> id) do
      %SavedMultiboard{} = m ->
        {:ok, _} = Slipdock.Multiboard.delete_saved(m)

        {:noreply, socket |> load_boards() |> put_flash(:info, "Multiboard “#{m.name}” deleted.")}

      _ ->
        {:noreply, socket}
    end
  end

  # The layout and the sort are this person's own, kept between visits. An
  # unknown value is dropped by the changeset, so the view stays as it was.
  defp save_view(socket, attrs) do
    case Accounts.update_board_view(socket.assigns.current_user, attrs) do
      {:ok, user} ->
        assign(socket,
          current_user: user,
          board_layout: user.board_layout,
          sort: user.board_sort
        )

      {:error, _} ->
        socket
    end
  end

  defp find_board(socket, id) do
    Enum.find(
      socket.assigns.boards ++ socket.assigns.archived,
      &(to_string(&1.id) == to_string(id))
    )
  end

  # A board, or a multiboard listed among them as "multiboard-<id>": what a
  # drag or a nudge moves.
  defp find_tile(socket, "multiboard-" <> id),
    do:
      Enum.find(Map.values(socket.assigns.multiboards), &(to_string(&1.multiboard.id) == id))[
        :multiboard
      ]

  defp find_tile(socket, id), do: find_board(socket, id)

  # How a board or a multiboard is told apart from the rest of the list, in the
  # page and in what a drag sends back.
  defp tile_key(%SavedMultiboard{id: id}), do: "multiboard-#{id}"
  defp tile_key(%Board{id: id}), do: to_string(id)

  # Archiving and deleting are the owner's alone, the way board settings are.
  defp with_owned_board(socket, id, fun) do
    board = find_board(socket, id)

    if board && Access.board_permission(socket.assigns.current_user, board) == :owner do
      {:noreply, fun.(board)}
    else
      {:noreply, put_flash(socket, :error, "Only the board's owner can do that.")}
    end
  end

  # The code follows the name until the user types one of their own; emptying
  # the field hands it back to us.
  defp sync_code(params, auto_code) do
    typed = String.trim(to_string(params["code"] || ""))
    name = String.trim(to_string(params["name"] || ""))

    cond do
      typed != "" and typed != auto_code -> {params, nil}
      name == "" -> {Map.put(params, "code", ""), ""}
      true -> suggest(params, name)
    end
  end

  defp suggest(params, name) do
    code = Boards.suggest_code(name)
    {Map.put(params, "code", code), code}
  end

  defp sorts, do: @sorts

  defp done_count(board), do: Enum.count(board.cards, & &1.completed)

  # Whose board this is. A board with no owner predates accounts and is open
  # to whoever finds it, which is worth saying rather than leaving blank.
  defp owner_name(%Board{owner: %User{} = owner}), do: User.display_name(owner)
  defp owner_name(_board), do: "nobody yet"

  defp percent_done(board) do
    case length(board.cards) do
      0 -> nil
      total -> round(done_count(board) / total * 100)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      waiting_count={@waiting_count}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:boards}
      wordmark
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <.page id="boards-home" width="full">
          <%!-- Above your own boards because it is for now, not for keeps:
                the support sessions you hold, and what each lets you read. --%>
          <section
            :for={%{session: session, subject: subject, boards: boards} <- @supported}
            id={"supporting-#{session.id}"}
            class="mb-6 rounded-2xl bg-warning/10 p-4 ring-1 ring-warning/30"
          >
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div class="min-w-0">
                <h2 class="flex items-center gap-2 text-sm font-semibold">
                  <.icon name="hero-lifebuoy" class="size-4 text-warning" />
                  Supporting {User.display_name(subject)}
                </h2>
                <p class="mt-0.5 text-xs text-base-content/60">
                  Read only, for another {support_time_left(session.expires_at)} — “{session.reason}”.
                  They have been told.
                </p>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="end_support"
                phx-value-id={session.id}
              >
                End now
              </button>
            </div>
            <div class="mt-3">
              <.support_board_links id={"supporting-boards-#{session.id}"} boards={boards} />
            </div>
          </section>

          <%!-- The wordmark is already in the header beside the logo, so the
               page's title says what the page is (#1714). --%>
          <.page_header title="Boards">
            <:meta>
              <%!-- The other way to read every board: not their cards, but
                   everything written on them: the one wiki (W-2201). It sits
                   with the count, on the left (#1662). --%>
              <.link
                id="open-wiki"
                navigate={~p"/wiki"}
                class="font-medium text-base-content/80 hover:text-primary"
              >
                <.icon name="hero-book-open" class="size-4 align-text-bottom" /> Wiki
              </.link>
              <span aria-hidden="true">·</span>
              <span id="board-count">
                {length(@boards)} {if length(@boards) == 1, do: "board", else: "boards"}
              </span>
              <span :if={@multiboards != %{}} aria-hidden="true">·</span>
              <span :if={@multiboards != %{}} id="multiboard-count">
                {map_size(@multiboards)} {if map_size(@multiboards) == 1,
                  do: "multiboard",
                  else: "multiboards"}
              </span>
            </:meta>
            <:actions>
              <button
                :if={length(@tiles) > 1}
                id="reorder-boards"
                type="button"
                class={["btn btn-sm", if(@reordering, do: "btn-primary", else: "btn-ghost")]}
                phx-click="toggle_reorder"
                aria-pressed={to_string(@reordering)}
                title="Drag boards and multiboards into your own order"
              >
                <.icon
                  name={if @reordering, do: "hero-check", else: "hero-arrows-up-down"}
                  class="size-4"
                />
                <span class="hidden sm:inline">{if @reordering, do: "Done", else: "Reorder"}</span>
              </button>
              <form id="board-sort" phx-change="set_sort">
                <select
                  name="sort"
                  class="select select-sm w-40"
                  title="The order your boards are listed in — yours alone"
                >
                  <option :for={{key, label} <- sorts()} value={key} selected={@sort == key}>
                    {label}
                  </option>
                </select>
              </form>
              <div class="join" role="group" aria-label="Layout">
                <button
                  :for={
                    {key, icon, label} <- [
                      {"grid", "hero-squares-2x2", "Cards"},
                      {"compact", "hero-bars-3", "Compact list"}
                    ]
                  }
                  type="button"
                  class={["btn btn-sm join-item", @board_layout == key && "btn-active"]}
                  phx-click="set_layout"
                  phx-value-layout={key}
                  value={key}
                  title={label}
                  aria-pressed={to_string(@board_layout == key)}
                >
                  <.icon name={icon} class="size-4" />
                </button>
              </div>
              <%!-- The top cards of lists picked from any of them (#1479). --%>
              <.link
                id="open-multiboard"
                navigate={~p"/multiboard"}
                class="btn btn-ghost btn-sm"
                title="The top cards of lists from several boards, on one page"
              >
                <.icon name="hero-rectangle-group" class="size-4" />
                <span class="hidden sm:inline">Multiboard</span>
              </.link>
              <.link navigate={~p"/templates"} class="btn btn-ghost btn-sm">
                <.icon name="hero-view-columns" class="size-4" />
                <span class="hidden sm:inline">Templates</span>
              </.link>
              <button :if={!@creating} class="btn btn-primary btn-sm" phx-click="start_create">
                <.icon name="hero-plus" class="size-4" /> New board
              </button>
            </:actions>
          </.page_header>

          <div
            :if={@creating}
            class="kanban-pop mb-8 rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <.form
              for={@form}
              id="new-board"
              phx-change="validate"
              phx-submit="create"
              class="space-y-4"
            >
              <div class="flex flex-col gap-4 sm:flex-row">
                <div class="flex-1">
                  <.input
                    field={@form[:name]}
                    label="Board name"
                    placeholder="e.g. Product launch"
                    phx-hook="Focus"
                  />
                </div>
                <div class="sm:w-40">
                  <.input
                    field={@form[:code]}
                    label="Code"
                    placeholder="auto"
                    maxlength={Board.code_length()}
                    class="w-full input font-mono"
                    title="A short handle for this board, used in links and on the command line"
                  />
                </div>
                <div class="flex-1">
                  <.input
                    field={@form[:description]}
                    label="Description (optional)"
                    placeholder="What is this board for?"
                  />
                </div>
              </div>
              <label class="block">
                <span class="mb-1 block text-sm font-medium">Lists</span>
                <select name="template" class="select w-full max-w-md">
                  <option value="" selected={@template_id in [nil, ""]}>
                    Default (Backlog · To Do · In Progress · Done)
                  </option>
                  <option
                    :for={t <- @templates}
                    value={t.id}
                    selected={to_string(t.id) == @template_id}
                  >
                    {t.name} ({Enum.map_join(t.columns, " · ", & &1["name"])})
                  </option>
                  <option value="custom" selected={@template_id == "custom"}>
                    Custom lists…
                  </option>
                </select>
              </label>
              <div :if={@template_id == "custom"} id="new-board-lists" class="max-w-md space-y-2">
                <.input
                  type="textarea"
                  id="new-board-lists-text"
                  name="lists"
                  value={@custom_lists}
                  rows="5"
                  label="Your lists, one per line"
                  errors={errors_on(@form, :columns)}
                />
                <p class="text-xs text-base-content/50">
                  Lists named like To Do, In Progress or Done count as such; set the rest in the
                  board's settings afterwards.
                </p>
                <.input
                  type="checkbox"
                  id="new-board-save-template"
                  name="save_template"
                  value={@save_template}
                  label="Save these lists as a template"
                />
                <.input
                  :if={@save_template}
                  id="new-board-template-name"
                  name="template_name"
                  value={@template_name}
                  label="Template name"
                  placeholder={@form[:name].value || "the board's name"}
                  errors={errors_on(@form, :save_template)}
                />
              </div>
              <div :if={sprint_template?(@templates, @template_id)} id="new-board-sources">
                <span class="mb-1 block text-sm font-medium">Plan sprints from</span>
                <p class="mb-2 text-xs text-base-content/50">
                  The boards whose cards go into these sprints, and which of their lists to show
                  when planning one. You can change this in the board's settings.
                </p>
                <div class="max-w-xl">
                  <.sources_fields choices={@source_choices || []} chosen={@sources_chosen} />
                </div>
              </div>
              <div>
                <span class="mb-2 block text-sm font-medium">Colour</span>
                <div class="flex flex-wrap gap-2">
                  <.color_swatch
                    :for={{name, _label} <- Palette.all()}
                    color={name}
                    selected={@new_color == name}
                    phx-click="pick_color"
                    phx-value-color={name}
                  />
                </div>
              </div>
              <div class="flex justify-end gap-2">
                <button type="button" class="btn btn-ghost" phx-click="cancel_create">Cancel</button>
                <button type="submit" class="btn btn-primary">Create board</button>
              </div>
            </.form>
          </div>

          <div
            :if={@tiles == [] and @archived == [] and !@creating}
            class="rounded-2xl border-2 border-dashed border-base-content/15 p-16 text-center"
          >
            <div class="mx-auto mb-4 flex size-14 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-view-columns" class="size-7" />
            </div>
            <h2 class="section-title">No boards yet</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Create your first board to get started.
            </p>
            <div class="mt-6 flex justify-center gap-2">
              <button
                id="new-board-tile"
                type="button"
                class="btn btn-primary"
                phx-click="start_create"
              >
                <.icon name="hero-plus" class="size-4" /> Add a new board
              </button>
            </div>
          </div>

          <div
            :if={@tiles == [] and @archived != []}
            class="rounded-2xl border-2 border-dashed border-base-content/15 p-10 text-center text-sm text-base-content/60"
          >
            <p>Every board you can see is archived. Open Archived below to bring one back.</p>
            <button
              :if={!@creating}
              id="new-board-tile"
              type="button"
              class="btn btn-primary btn-sm mt-4"
              phx-click="start_create"
            >
              <.icon name="hero-plus" class="size-4" /> Add a new board
            </button>
          </div>

          <div
            :if={@reordering and @tiles != []}
            id="reorder-hint"
            class="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-xl bg-primary/10 px-4 py-2.5 text-sm ring-1 ring-primary/30"
            phx-window-keydown="exit_reorder"
            phx-key="Escape"
          >
            <span class="inline-flex items-center gap-2">
              <.icon name="hero-arrows-pointing-out" class="size-4 text-primary" />
              Drag boards and multiboards into the order you want. Each drop is saved.
            </span>
            <button type="button" class="btn btn-primary btn-xs" phx-click="exit_reorder">
              Done
            </button>
          </div>

          <.board_grid
            :if={@board_layout == "grid" and @tiles != []}
            id="boards"
            boards={@tiles}
            multiboards={@multiboards}
            hotkeys={@hotkeys}
            current_user={@current_user}
            sort={@sort}
            reordering={@reordering}
            add_tile={!@creating and !@reordering and not Enum.any?(@tiles, &match?(%Board{}, &1))}
          />
          <.board_table
            :if={@board_layout == "compact" and @tiles != []}
            id="boards"
            boards={@tiles}
            multiboards={@multiboards}
            hotkeys={@hotkeys}
            current_user={@current_user}
            sort={@sort}
            reordering={@reordering}
          />

          <section :if={@archived != []} class="mt-10">
            <button
              type="button"
              class="btn btn-ghost btn-sm gap-2 px-2"
              phx-click="toggle_archived"
              aria-expanded={to_string(@show_archived)}
            >
              <.icon
                name={if @show_archived, do: "hero-chevron-down", else: "hero-chevron-right"}
                class="size-4"
              />
              <.icon name="hero-archive-box" class="size-4" /> Archived
              <span class="badge badge-ghost badge-sm">{length(@archived)}</span>
            </button>
            <p :if={@show_archived} class="mb-3 mt-1 text-sm text-base-content/60">
              Put away, not deleted: every card, tag and comment is still there, and restoring a
              board puts it back where it was.
            </p>
            <.board_grid
              :if={@show_archived and @board_layout == "grid"}
              id="archived-boards"
              boards={@archived}
              hotkeys={@hotkeys}
              current_user={@current_user}
              sort={@sort}
              archived
            />
            <.board_table
              :if={@show_archived and @board_layout == "compact"}
              id="archived-boards"
              boards={@archived}
              hotkeys={@hotkeys}
              current_user={@current_user}
              sort={@sort}
              archived
            />
          </section>

          <section :if={@shared_cards != []} class="mt-10">
            <h2 class="section-title">Cards shared with you</h2>
            <p class="text-sm text-base-content/60">Single cards other people gave you access to.</p>
            <ul class="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5">
              <li :for={card <- @shared_cards} id={"shared-card-#{card.id}"}>
                <.link
                  navigate={~p"/boards/#{card.board_id}/cards/#{card.id}"}
                  class="block rounded-xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/10 hover:ring-primary/40"
                >
                  <p class={[
                    "truncate text-sm font-medium",
                    card.completed && "opacity-60"
                  ]}>
                    {card.title}
                  </p>
                  <p class="mt-0.5 truncate text-xs text-base-content/50">
                    {card.board.name} · {card.column.name}
                  </p>
                  <div :if={card.tags != []} class="mt-1.5 flex flex-wrap gap-1">
                    <.tag_chip :for={tag <- card.tags} tag={tag} size="xs" />
                  </div>
                </.link>
              </li>
            </ul>
          </section>
        </.page>
      </div>
    </Layouts.app>
    """
  end

  ## The two layouts -----------------------------------------------------------

  attr :id, :string, required: true
  # Boards, and on the main list the multiboards among them (see `tiles`).
  attr :boards, :list, required: true
  # And each saved multiboard's, by its id (see `multiboard_entries/2`).
  attr :multiboards, :map, default: %{}
  attr :hotkeys, :map, default: %{}
  attr :current_user, :map, required: true
  attr :sort, :string, required: true
  attr :archived, :boolean, default: false
  # Reorder mode (#1485): the whole tile is the handle, and nothing in it
  # opens or clicks.
  attr :reordering, :boolean, default: false
  # A board-sized "+ Add a new board" tile after the last one, which opens the
  # same form as the New board button: only while there are no boards (just
  # multiboards), as it would otherwise repeat that button (#1716).
  attr :add_tile, :boolean, default: false

  defp board_grid(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Sortable"
      data-group={@id}
      data-event="reorder"
      data-handle={!@reordering && ".board-handle"}
      data-draggable="[data-id]"
      data-disabled={to_string(@archived or @sort != "manual")}
      data-reordering={@reordering && "true"}
      class={[
        "grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5",
        @reordering && reorder_class()
      ]}
    >
      <%= for tile <- @boards do %>
        <.multiboard_card
          :if={match?(%SavedMultiboard{}, tile)}
          entry={@multiboards[tile.id]}
          sort={@sort}
          tiles={@boards}
        />
        <.board_card
          :if={match?(%Board{}, tile)}
          board={tile}
          hotkey={@hotkeys[tile.id]}
          boards={@boards}
          current_user={@current_user}
          sort={@sort}
          archived={@archived}
        />
      <% end %>
      <button
        :if={@add_tile}
        id="new-board-tile"
        type="button"
        phx-click="start_create"
        class={add_tile_class()}
      >
        <.icon name="hero-plus" class="size-5" /> Add a new board
      </button>
    </div>
    """
  end

  # Every tile a grab target, outlined, with its links and menus inert so a
  # press starts a drag rather than opening the board.
  defp reorder_class,
    do:
      "select-none [&>[data-id]]:cursor-grab [&>[data-id]]:outline-2 [&>[data-id]]:outline-dashed [&>[data-id]]:outline-offset-2 [&>[data-id]]:outline-primary/50 [&>[data-id]_*]:pointer-events-none"

  defp add_tile_class,
    do:
      "flex min-h-24 items-center justify-center gap-2 rounded-2xl border-2 border-dashed border-base-content/15 text-base-content/60 transition hover:border-primary/50 hover:text-primary sm:min-h-40"

  @tile_class "group relative overflow-hidden rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10 transition hover:-translate-y-0.5 hover:shadow-lg"

  attr :board, :map, required: true
  attr :hotkey, :integer, default: nil
  attr :boards, :list, required: true
  attr :current_user, :map, required: true
  attr :sort, :string, required: true
  attr :archived, :boolean, required: true

  defp board_card(assigns) do
    assigns = assign(assigns, :tile_class, @tile_class)

    ~H"""
    <div
      id={"board-#{@board.id}"}
      data-id={@board.id}
      class={[
        @tile_class,
        @archived && "opacity-70"
      ]}
    >
      <.link navigate={SlipdockWeb.SwimlaneComponents.board_home_path(@board)} class="block">
        <div
          data-role="tile-band"
          class={["h-1.5 bg-gradient-to-br", Palette.gradient(@board.color)]}
        >
        </div>
        <div class="p-3.5 sm:p-4">
          <h2 class="flex items-center gap-2 truncate pr-20 section-title">
            <span class="truncate" title={board_handles_title(@board, @board.name, @hotkey)}>
              {@board.name}
            </span>
            <span
              :if={@board.owner_id != @current_user.id}
              class="badge badge-ghost badge-xs max-w-40 shrink-0"
              title={"Owned by #{owner_name(@board)}"}
            >
              <span class="truncate">shared by {owner_name(@board)}</span>
            </span>
            <%!-- The code and keys are for the CLI and the keyboard: shown on
                  hover or focus, not drawn as chips on every tile (#1716). --%>
            <span
              data-role="tile-handles"
              class="hidden shrink-0 items-center gap-1 font-normal group-focus-within:inline-flex group-hover:inline-flex"
            >
              <span :if={@board.code} class="font-mono text-2xs text-base-content/60">
                {@board.code}
              </span>
              <.board_keys board={@board} hotkey={@hotkey} />
            </span>
          </h2>
          <p class="mt-0.5 line-clamp-2 text-sm text-base-content/60 sm:min-h-[1.25rem]">
            {@board.description}
          </p>
          <% total = length(@board.cards) %>
          <div class="mt-2.5 flex items-center gap-3 text-xs text-base-content/60 sm:mt-4">
            <span class="inline-flex items-center gap-1">
              <.icon name="hero-view-columns" class="size-3.5" /> {length(@board.columns)} lists
            </span>
            <span class="inline-flex items-center gap-1">
              <.icon name="hero-rectangle-stack" class="size-3.5" /> {total} cards
            </span>
            <span :if={total > 0} class="ml-auto font-medium">
              {percent_done(@board)}%
            </span>
          </div>
          <progress
            :if={total > 0}
            class="progress progress-success mt-2 h-1.5 w-full"
            value={done_count(@board)}
            max={total}
          ></progress>
        </div>
      </.link>
      <div class="absolute right-11 top-3 flex items-center gap-1 sm:top-3.5">
        <span
          :if={!@archived and @sort == "manual"}
          class="board-handle btn btn-circle btn-ghost btn-sm cursor-grab bg-base-100/70 opacity-0 backdrop-blur transition group-hover:opacity-100 no-hover:opacity-100"
          title="Drag to reorder"
        >
          <.icon name="hero-bars-2" class="size-4" />
        </span>
        <span :if={@archived} class="badge badge-warning badge-sm">archived</span>
      </div>
      <.board_menu
        board={@board}
        current_user={@current_user}
        sort={@sort}
        boards={@boards}
        archived={@archived}
        class="dropdown dropdown-end absolute right-2 top-3 opacity-0 sm:top-3.5 transition group-hover:opacity-100 focus-within:opacity-100 no-hover:opacity-100"
        button_class="btn btn-circle btn-ghost btn-sm bg-base-100/70 backdrop-blur"
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :boards, :list, required: true
  attr :multiboards, :map, default: %{}
  attr :hotkeys, :map, default: %{}
  attr :current_user, :map, required: true
  attr :sort, :string, required: true
  attr :archived, :boolean, default: false
  attr :reordering, :boolean, default: false

  defp board_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/50">
            <th :if={!@archived and @sort == "manual"} class="w-8"></th>
            <th>Board</th>
            <th class="hidden md:table-cell">Description</th>
            <th class="hidden lg:table-cell">Code</th>
            <th class="w-16 text-right">Lists</th>
            <th class="w-16 text-right">Cards</th>
            <th class="w-32">Done</th>
            <th class="hidden w-24 sm:table-cell">Active</th>
            <th class="w-10"></th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-hook="Sortable"
          data-group={@id}
          data-event="reorder"
          data-handle={!@reordering && ".board-handle"}
          data-disabled={to_string(@archived or @sort != "manual")}
          data-reordering={@reordering && "true"}
          class={@reordering && reorder_class()}
        >
          <%= for board <- @boards do %>
            <.multiboard_row
              :if={match?(%SavedMultiboard{}, board)}
              entry={@multiboards[board.id]}
              sort={@sort}
              tiles={@boards}
            />
            <tr
              :if={match?(%Board{}, board)}
              id={"board-#{board.id}"}
              data-id={board.id}
              class={["group hover:bg-base-200/60", @archived && "opacity-70"]}
            >
              <td :if={!@archived and @sort == "manual"} class="board-handle cursor-grab align-middle">
                <.icon
                  name="hero-bars-2"
                  class="size-4 text-base-content/30 group-hover:text-base-content/60"
                />
              </td>
              <td class="align-middle">
                <.link
                  navigate={SlipdockWeb.SwimlaneComponents.board_home_path(board)}
                  class="flex items-center gap-2"
                >
                  <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(board.color)]}></span>
                  <span
                    class="max-w-56 truncate font-medium"
                    title={board_handles_title(board, board.name, @hotkeys[board.id])}
                  >
                    {board.name}
                  </span>
                  <span
                    :if={board.owner_id != @current_user.id}
                    class="badge badge-ghost badge-xs max-w-40 shrink-0"
                    title={"Owned by #{owner_name(board)}"}
                  >
                    <span class="truncate">shared by {owner_name(board)}</span>
                  </span>
                  <span :if={@archived} class="badge badge-warning badge-xs shrink-0">archived</span>
                </.link>
              </td>
              <td class="hidden max-w-xs truncate text-base-content/60 md:table-cell">
                {board.description}
              </td>
              <%!-- The list layout's own column for the handles (#1716). --%>
              <td data-role="board-handles" class="hidden whitespace-nowrap lg:table-cell">
                <span class="inline-flex items-center gap-1">
                  <span :if={board.code} class="font-mono text-xs text-base-content/60">
                    {board.code}
                  </span>
                  <.board_keys board={board} hotkey={@hotkeys[board.id]} />
                </span>
              </td>
              <td class="text-right tabular-nums text-base-content/60">{length(board.columns)}</td>
              <td class="text-right tabular-nums text-base-content/60">{length(board.cards)}</td>
              <td>
                <div :if={percent_done(board)} class="flex items-center gap-2">
                  <progress
                    class="progress progress-success h-1.5 w-16"
                    value={done_count(board)}
                    max={length(board.cards)}
                  ></progress>
                  <span class="text-xs tabular-nums text-base-content/60">
                    {percent_done(board)}%
                  </span>
                </div>
                <span :if={is_nil(percent_done(board))} class="text-xs text-base-content/40">—</span>
              </td>
              <td class="hidden whitespace-nowrap text-xs text-base-content/50 sm:table-cell">
                {board.last_activity_at && relative_time(board.last_activity_at)}
              </td>
              <td>
                <.board_menu
                  board={board}
                  current_user={@current_user}
                  sort={@sort}
                  boards={@boards}
                  archived={@archived}
                  class="dropdown dropdown-end"
                  button_class="btn btn-ghost btn-xs btn-square"
                />
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :board, :map, required: true
  attr :hotkey, :integer, default: nil

  # The keys that reach a board: its switcher shortcut (b, then it), and the
  # reader's own Ctrl+Shift digit when they have given it one.
  defp board_keys(assigns) do
    ~H"""
    <kbd
      :if={@board.shortcut}
      class="kbd kbd-xs shrink-0 font-normal"
      title="Press b then this key to jump here"
    >
      {@board.shortcut}
    </kbd>
    <kbd
      :if={@hotkey}
      id={"board-hotkey-#{@board.id}"}
      class="kbd kbd-xs shrink-0 font-normal"
      title={"Ctrl+Shift+#{@hotkey} opens this board from any page"}
    >
      Ctrl+Shift+{@hotkey}
    </kbd>
    """
  end

  attr :board, :map, required: true
  attr :boards, :list, required: true
  attr :current_user, :map, required: true
  attr :sort, :string, required: true
  attr :archived, :boolean, required: true
  attr :class, :string, required: true
  attr :button_class, :string, required: true

  defp board_menu(assigns) do
    assigns =
      assign(assigns,
        owner?: assigns.board.owner_id == assigns.current_user.id,
        # Somebody else's board, on your list because they shared it. Boards
        # with no owner at all predate accounts and are nobody's share.
        shared?:
          not is_nil(assigns.board.owner_id) and
            assigns.board.owner_id != assigns.current_user.id,
        first?: tile_key(List.first(assigns.boards)) == tile_key(assigns.board),
        last?: tile_key(List.last(assigns.boards)) == tile_key(assigns.board)
      )

    ~H"""
    <div
      :if={@owner? or @shared? or not is_nil(@board.code) or (@sort == "manual" and not @archived)}
      class={@class}
    >
      <div tabindex="0" role="button" class={@button_class} title="More">
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </div>
      <ul
        tabindex="0"
        class="menu dropdown-content z-10 w-44 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
      >
        <li :if={@sort == "manual" and not @archived and not @first?}>
          <button phx-click="nudge" phx-value-id={@board.id} phx-value-dir="up">
            <.icon name="hero-arrow-up" class="size-4" /> Move up
          </button>
        </li>
        <li :if={@sort == "manual" and not @archived and not @last?}>
          <button phx-click="nudge" phx-value-id={@board.id} phx-value-dir="down">
            <.icon name="hero-arrow-down" class="size-4" /> Move down
          </button>
        </li>
        <li :if={@board.code}>
          <button
            type="button"
            id={"copy-code-#{@board.id}"}
            phx-hook="CopyText"
            data-target={"board-code-#{@board.id}"}
          >
            <.icon name="hero-clipboard" class="size-4" />
            <span data-label>Copy board code</span>
            <span
              id={"board-code-#{@board.id}"}
              class="ml-auto font-mono text-2xs text-base-content/60"
            >
              {@board.code}
            </span>
          </button>
        </li>
        <li :if={@shared?}>
          <.link navigate={~p"/boards/#{@board}/shared"}>
            <.icon name="hero-user-plus" class="size-4" /> Shared
          </.link>
        </li>
        <li :if={@owner? and not @archived}>
          <button
            phx-click="archive"
            phx-value-id={@board.id}
            data-confirm={"Archive “#{@board.name}”? It comes off your boards and the switcher, but nothing on it is lost."}
          >
            <.icon name="hero-archive-box" class="size-4" /> Archive
          </button>
        </li>
        <li :if={@owner? and @archived}>
          <button phx-click="unarchive" phx-value-id={@board.id}>
            <.icon name="hero-archive-box-arrow-down" class="size-4" /> Restore
          </button>
        </li>
        <li :if={@owner?}>
          <button
            class="text-error"
            phx-click="delete"
            phx-value-id={@board.id}
            data-confirm={"Delete “#{@board.name}” and all of its cards? This cannot be undone."}
          >
            <.icon name="hero-trash" class="size-4" /> Delete board
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :sort, :string, required: true
  attr :tiles, :list, required: true

  # A saved multiboard's card, among the boards' (#1482): its colour, its
  # name, and where its lists come from.
  defp multiboard_card(assigns) do
    assigns = assign(assigns, tile_class: @tile_class, mb: assigns.entry.multiboard)

    ~H"""
    <div id={"multiboard-#{@mb.id}"} data-id={tile_key(@mb)} class={@tile_class}>
      <.link id={"multiboard-tile-#{@mb.id}"} navigate={~p"/multiboard/#{@mb.id}"} class="block">
        <div data-role="tile-band" class={["h-1.5 bg-gradient-to-br", Palette.gradient(@mb.color)]}>
        </div>
        <div class="p-3.5 sm:p-4">
          <h2 class="flex items-center gap-2 truncate pr-20 section-title">
            <.icon name="hero-squares-2x2" class="size-4 shrink-0 text-base-content/50" />
            <span class="truncate">{@mb.name}</span>
            <span class="chip chip-line shrink-0 text-2xs font-normal">multiboard</span>
          </h2>
          <p class="mt-0.5 line-clamp-2 text-sm text-base-content/60 sm:min-h-[1.25rem]">
            <%= if @entry.boards == [] do %>
              No lists chosen yet
            <% else %>
              {Enum.map_join(@entry.boards, " · ", & &1.name)}
            <% end %>
          </p>
          <div class="mt-2.5 flex items-center gap-3 text-xs text-base-content/60 sm:mt-4">
            <span class="inline-flex items-center gap-1">
              <.icon name="hero-view-columns" class="size-3.5" />
              {@entry.lists} {if @entry.lists == 1, do: "list", else: "lists"}
            </span>
            <span class="inline-flex items-center gap-1">
              <.icon name="hero-queue-list" class="size-3.5" /> top {@mb.top}
            </span>
          </div>
        </div>
      </.link>
      <div class="absolute right-11 top-3 flex items-center gap-1 sm:top-3.5">
        <span
          :if={@sort == "manual"}
          class="board-handle btn btn-circle btn-ghost btn-sm cursor-grab bg-base-100/70 opacity-0 backdrop-blur transition group-hover:opacity-100 no-hover:opacity-100"
          title="Drag to reorder"
        >
          <.icon name="hero-bars-2" class="size-4" />
        </span>
      </div>
      <.multiboard_menu
        multiboard={@mb}
        sort={@sort}
        tiles={@tiles}
        class="dropdown dropdown-end absolute right-2 top-3 opacity-0 sm:top-3.5 transition group-hover:opacity-100 focus-within:opacity-100 no-hover:opacity-100"
        button_class="btn btn-circle btn-ghost btn-sm bg-base-100/70 backdrop-blur"
      />
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :sort, :string, required: true
  attr :tiles, :list, required: true

  # The same multiboard as a row of the compact list.
  defp multiboard_row(assigns) do
    assigns = assign(assigns, mb: assigns.entry.multiboard)

    ~H"""
    <tr id={"multiboard-#{@mb.id}"} data-id={tile_key(@mb)} class="group hover:bg-base-200/60">
      <td :if={@sort == "manual"} class="board-handle cursor-grab align-middle">
        <.icon
          name="hero-bars-2"
          class="size-4 text-base-content/30 group-hover:text-base-content/60"
        />
      </td>
      <td class="align-middle">
        <.link
          id={"multiboard-tile-#{@mb.id}"}
          navigate={~p"/multiboard/#{@mb.id}"}
          class="flex items-center gap-2"
        >
          <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@mb.color)]}></span>
          <span class="max-w-56 truncate font-medium">{@mb.name}</span>
          <span class="chip chip-line shrink-0 text-2xs font-normal">multiboard</span>
        </.link>
      </td>
      <td class="hidden max-w-xs truncate text-base-content/60 md:table-cell">
        {Enum.map_join(@entry.boards, " · ", & &1.name)}
      </td>
      <td class="text-right tabular-nums text-base-content/60">{@entry.lists}</td>
      <td class="text-right text-base-content/40">—</td>
      <td><span class="text-xs text-base-content/40">—</span></td>
      <td class="hidden sm:table-cell"></td>
      <td>
        <.multiboard_menu
          multiboard={@mb}
          sort={@sort}
          tiles={@tiles}
          class="dropdown dropdown-end"
          button_class="btn btn-ghost btn-xs btn-square"
        />
      </td>
    </tr>
    """
  end

  attr :multiboard, :map, required: true
  attr :sort, :string, required: true
  attr :tiles, :list, required: true
  attr :class, :string, required: true
  attr :button_class, :string, required: true

  # A saved multiboard's own menu: moving it in your order, its colour, and
  # deleting it. It is always yours, so the menu is always there.
  defp multiboard_menu(assigns) do
    key = tile_key(assigns.multiboard)

    assigns =
      assign(assigns,
        key: key,
        first?: tile_key(List.first(assigns.tiles)) == key,
        last?: tile_key(List.last(assigns.tiles)) == key
      )

    ~H"""
    <div class={@class}>
      <div tabindex="0" role="button" class={@button_class} title="More">
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </div>
      <ul
        tabindex="0"
        class="menu dropdown-content z-10 w-52 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
      >
        <li :if={@sort == "manual" and not @first?}>
          <button phx-click="nudge" phx-value-id={@key} phx-value-dir="up">
            <.icon name="hero-arrow-up" class="size-4" /> Move up
          </button>
        </li>
        <li :if={@sort == "manual" and not @last?}>
          <button phx-click="nudge" phx-value-id={@key} phx-value-dir="down">
            <.icon name="hero-arrow-down" class="size-4" /> Move down
          </button>
        </li>
        <li class="menu-title px-3 pb-1 pt-2 text-xs">Colour</li>
        <li class="px-2 pb-2">
          <div class="flex flex-wrap gap-1.5 hover:bg-transparent active:bg-transparent">
            <.color_swatch
              :for={name <- Palette.names()}
              id={"multiboard-color-#{@multiboard.id}-#{name}"}
              color={name}
              selected={@multiboard.color == name}
              class="size-5"
              phx-click="multiboard_color"
              phx-value-id={@multiboard.id}
              phx-value-color={name}
            />
          </div>
        </li>
        <li>
          <button
            id={"multiboard-delete-#{@multiboard.id}"}
            phx-click="delete_multiboard"
            phx-value-id={@multiboard.id}
            data-confirm={"Delete the multiboard “#{@multiboard.name}”? The boards and their cards stay as they are."}
            class="text-error"
          >
            <.icon name="hero-trash" class="size-4" /> Delete
          </button>
        </li>
      </ul>
    </div>
    """
  end
end

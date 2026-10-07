defmodule SlipdockWeb.BoardLive.Index do
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents

  import SlipdockWeb.SprintPlanComponents,
    only: [sources_fields: 1, parse_sources: 2, chosen_from: 1]

  alias Slipdock.{Access, Accounts, Boards, Sprints}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Palette

  # What the sort control offers, in the order it offers it.
  @sorts [
    {"manual", "My order"},
    {"name", "Name"},
    {"active", "Recently active"},
    {"newest", "Newest first"},
    {"oldest", "Oldest first"},
    {"cards", "Most cards"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Boards.subscribe_all()
      Boards.subscribe_templates()
    end

    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(page_title: "Boards", creating: false, new_color: "indigo", template_id: nil)
     |> assign(auto_code: "", source_choices: nil, sources_chosen: %{})
     |> assign(board_layout: user.board_layout || "grid", sort: user.board_sort || "manual")
     |> assign(show_archived: false)
     |> assign(templates: Boards.list_templates())
     |> assign(:form, to_form(Boards.change_board(%Board{})))
     |> load_boards()}
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

  defp sprint_template?(templates, id),
    do: Enum.any?(templates, &(to_string(&1.id) == id and &1.kind == "sprints"))

  defp load_boards(socket) do
    %{current_user: user, sort: sort} = socket.assigns

    assign(socket,
      boards: user |> Access.list_boards(activity: true) |> Boards.sort_boards(sort),
      archived:
        user |> Access.list_boards(archived: true, activity: true) |> Boards.sort_boards(sort),
      shared_cards: Access.shared_cards(user)
    )
  end

  @impl true
  def handle_info({:boards_changed}, socket) do
    Boards.drain_boards_changed()
    {:noreply, load_boards(socket)}
  end

  def handle_info({:templates_changed}, socket),
    do: {:noreply, assign(socket, templates: Boards.list_templates())}

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_create", _, socket) do
    {:noreply,
     assign(socket,
       creating: true,
       auto_code: "",
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
     |> put_sources(all)}
  end

  def handle_event("create", %{"board" => params} = all, socket) do
    template =
      case all["template"] do
        id when id in [nil, ""] -> nil
        id -> Enum.find(socket.assigns.templates, &(to_string(&1.id) == id))
      end

    params = Map.put(params, "color", socket.assigns.new_color)

    case Boards.create_board(params,
           template: template,
           owner_id: socket.assigns.current_user.id
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
        {:noreply, assign(socket, form: to_form(changeset))}
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
    {:noreply, socket |> save_view(%{"board_sort" => sort}) |> load_boards()}
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
    case find_board(socket, id) do
      nil ->
        {:noreply, socket}

      board ->
        Boards.place_board(socket.assigns.current_user, board, before, socket.assigns.boards)
        {:noreply, load_boards(socket)}
    end
  end

  # The same move without a mouse, from the board's own menu.
  def handle_event("nudge", %{"id" => id, "dir" => dir}, socket) do
    direction = if dir == "up", do: :up, else: :down

    case find_board(socket, id) do
      nil ->
        {:noreply, socket}

      board ->
        Boards.nudge_board(socket.assigns.current_user, board, direction, socket.assigns.boards)
        {:noreply, load_boards(socket)}
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
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:boards}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-6xl px-4 py-6 sm:py-10 sm:px-6">
          <div class="mb-8 flex flex-wrap items-end justify-between gap-4">
            <div>
              <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Your boards</h1>
              <p class="mt-1 text-sm text-base-content/60">
                {length(@boards)} {if length(@boards) == 1, do: "board", else: "boards"} · drag cards, flag them, tag them, get things done.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
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
              <%!-- The other way to read every board: not their cards, but
                    everything written on them (see `SlipdockWeb.WikiLive.All`). --%>
              <.link navigate={~p"/wiki"} class="btn btn-ghost btn-sm">
                <.icon name="hero-book-open" class="size-4" />
                <span class="hidden sm:inline">Wiki</span>
              </.link>
              <.link navigate={~p"/templates"} class="btn btn-ghost btn-sm">
                <.icon name="hero-view-columns" class="size-4" />
                <span class="hidden sm:inline">Templates</span>
              </.link>
              <button :if={!@creating} class="btn btn-primary btn-sm" phx-click="start_create">
                <.icon name="hero-plus" class="size-4" /> New board
              </button>
            </div>
          </div>

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
                </select>
              </label>
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
            :if={@boards == [] and @archived == [] and !@creating}
            class="rounded-2xl border-2 border-dashed border-base-content/15 p-16 text-center"
          >
            <div class="mx-auto mb-4 flex size-14 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-view-columns" class="size-7" />
            </div>
            <h2 class="text-lg font-semibold">No boards yet</h2>
            <p class="mt-1 text-sm text-base-content/60">Create your first board to get started.</p>
            <button class="btn btn-primary mt-6" phx-click="start_create">
              <.icon name="hero-plus" class="size-4" /> New board
            </button>
          </div>

          <p
            :if={@boards == [] and @archived != []}
            class="rounded-2xl border-2 border-dashed border-base-content/15 p-10 text-center text-sm text-base-content/60"
          >
            Every board you can see is archived. Open Archived below to bring one back.
          </p>

          <.board_grid
            :if={@board_layout == "grid" and @boards != []}
            id="boards"
            boards={@boards}
            current_user={@current_user}
            sort={@sort}
          />
          <.board_table
            :if={@board_layout == "compact" and @boards != []}
            id="boards"
            boards={@boards}
            current_user={@current_user}
            sort={@sort}
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
              current_user={@current_user}
              sort={@sort}
              archived
            />
            <.board_table
              :if={@show_archived and @board_layout == "compact"}
              id="archived-boards"
              boards={@archived}
              current_user={@current_user}
              sort={@sort}
              archived
            />
          </section>

          <section :if={@shared_cards != []} class="mt-10">
            <h2 class="text-lg font-semibold">Cards shared with you</h2>
            <p class="text-sm text-base-content/60">Single cards other people gave you access to.</p>
            <ul class="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
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
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## The two layouts -----------------------------------------------------------

  attr :id, :string, required: true
  attr :boards, :list, required: true
  attr :current_user, :map, required: true
  attr :sort, :string, required: true
  attr :archived, :boolean, default: false

  defp board_grid(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Sortable"
      data-group={@id}
      data-event="reorder"
      data-handle=".board-handle"
      data-disabled={to_string(@archived or @sort != "manual")}
      class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
    >
      <div
        :for={board <- @boards}
        id={"board-#{board.id}"}
        data-id={board.id}
        class={[
          "group relative overflow-hidden rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10 transition hover:-translate-y-0.5 hover:shadow-lg",
          @archived && "opacity-70"
        ]}
      >
        <.link navigate={~p"/boards/#{board}"} class="block">
          <div class={["h-2 bg-gradient-to-br sm:h-20", Palette.gradient(board.color)]}></div>
          <div class="p-3.5 sm:p-4">
            <h2 class="flex items-center gap-2 truncate text-base font-semibold">
              <span class="truncate">{board.name}</span>
              <span
                :if={board.code}
                class="chip chip-line shrink-0 font-mono text-2xs font-normal"
                title="Board code"
              >
                {board.code}
              </span>
              <span
                :if={board.owner_id != @current_user.id}
                class="badge badge-ghost badge-xs max-w-40 shrink-0"
                title={"Owned by #{owner_name(board)}"}
              >
                <span class="truncate">shared by {owner_name(board)}</span>
              </span>
            </h2>
            <p class="mt-0.5 line-clamp-2 text-sm text-base-content/60 sm:min-h-[1.25rem]">
              {board.description}
            </p>
            <% total = length(board.cards) %>
            <div class="mt-2.5 flex items-center gap-3 text-xs text-base-content/60 sm:mt-4">
              <span class="inline-flex items-center gap-1">
                <.icon name="hero-view-columns" class="size-3.5" /> {length(board.columns)} lists
              </span>
              <span class="inline-flex items-center gap-1">
                <.icon name="hero-rectangle-stack" class="size-3.5" /> {total} cards
              </span>
              <span :if={total > 0} class="ml-auto font-medium">
                {percent_done(board)}%
              </span>
            </div>
            <progress
              :if={total > 0}
              class="progress progress-success mt-2 h-1.5 w-full"
              value={done_count(board)}
              max={total}
            ></progress>
          </div>
        </.link>
        <div class="absolute left-2 top-2 flex items-center gap-1">
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
          board={board}
          current_user={@current_user}
          sort={@sort}
          boards={@boards}
          archived={@archived}
          class="dropdown dropdown-end absolute right-2 top-2 opacity-0 transition group-hover:opacity-100 focus-within:opacity-100 no-hover:opacity-100"
          button_class="btn btn-circle btn-ghost btn-sm bg-base-100/70 backdrop-blur"
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :boards, :list, required: true
  attr :current_user, :map, required: true
  attr :sort, :string, required: true
  attr :archived, :boolean, default: false

  defp board_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/50">
            <th :if={!@archived and @sort == "manual"} class="w-8"></th>
            <th>Board</th>
            <th class="hidden md:table-cell">Description</th>
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
          data-handle=".board-handle"
          data-disabled={to_string(@archived or @sort != "manual")}
        >
          <tr
            :for={board <- @boards}
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
              <.link navigate={~p"/boards/#{board}"} class="flex items-center gap-2">
                <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(board.color)]}></span>
                <span class="max-w-56 truncate font-medium">{board.name}</span>
                <span
                  :if={board.code}
                  class="chip chip-line shrink-0 font-mono text-2xs font-normal"
                  title="Board code"
                >
                  {board.code}
                </span>
                <span
                  :if={board.shortcut}
                  class="hidden shrink-0 lg:inline"
                  title="Press b then this key to jump here"
                >
                  <kbd class="kbd kbd-xs">{board.shortcut}</kbd>
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
        </tbody>
      </table>
    </div>
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
        first?: List.first(assigns.boards).id == assigns.board.id,
        last?: List.last(assigns.boards).id == assigns.board.id
      )

    ~H"""
    <div :if={@owner? or @shared? or (@sort == "manual" and not @archived)} class={@class}>
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
end

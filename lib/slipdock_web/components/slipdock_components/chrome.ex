defmodule SlipdockWeb.SlipdockComponents.Chrome do
  @moduledoc "What surrounds the cards: the modal, the favourite heart, the quick-add row, the view switcher, the filter menu and the support session's links."
  use Phoenix.Component

  use Phoenix.VerifiedRoutes, endpoint: SlipdockWeb.Endpoint, router: SlipdockWeb.Router

  alias Phoenix.LiveView.JS
  alias Slipdock.Palette

  import SlipdockWeb.CoreComponents, only: [icon: 1, quick_chips: 1]
  import SlipdockWeb.SlipdockComponents.CardFace, only: [kind_icon: 1]
  import SlipdockWeb.SlipdockComponents.Marks
  import SlipdockWeb.SlipdockComponents.Schedule, only: [due_icon: 0]

  @doc """
  A label with one letter marked: the key that jumps to it.

  The card dialog's sections are reached by key — `SlipdockWeb.Shortcuts` writes
  them down and the `CardKeys` hook acts on them — and an underline is how a
  heading says which key is its own. Only while Alt (Option) is held, as menu
  accelerators do (#1728): at rest an underline on every heading reads as a
  rendering fault. `.keyed-key` in app.css draws it under `[data-show-keys]`. The letter is the first match in the
  label, case-insensitively; a key the label does not contain is rendered
  plainly rather than guessed at.
  """
  attr :key, :string, required: true
  attr :label, :string, required: true

  def keyed_label(assigns) do
    {before, letter, rest} = split_on_key(assigns.label, assigns.key)
    assigns = assign(assigns, before: before, letter: letter, rest: rest)

    ~H"""
    <span phx-no-format>{@before}<u :if={@letter != ""} class="keyed-key">{@letter}</u>{@rest}</span>
    """
  end

  defp split_on_key(label, key) do
    case :binary.match(String.downcase(label), String.downcase(key)) do
      {at, len} ->
        {binary_part(label, 0, at), binary_part(label, at, len),
         binary_part(label, at + len, byte_size(label) - at - len)}

      :nomatch ->
        {label, "", ""}
    end
  end

  ## Modal ------------------------------------------------------------------

  attr :id, :string, required: true
  attr :on_close, JS, required: true

  attr :size, :string,
    default: "md",
    doc:
      ~s("sm", "md", "lg", "xl", "page": 80% of the screen, for a long form like board settings, or "wide": 90%, for a card opened full screen)

  attr :keys, :boolean,
    default: false,
    doc: "give the dialog the keyboard: arrows, hjkl, PageUp/Down, Home/End and the section keys"

  slot :actions,
    doc: "buttons that sit in the top corner beside the close button, on the same row"

  slot :inner_block, required: true

  # Below `sm` the overlay is sized to the screen (`w-screen h-dvh`), not left
  # to `inset-0`: a page wider than the phone makes mobile Chrome widen the
  # layout viewport to fit it, and an `inset-0` overlay widens with it, leaving
  # the sheet half off the screen (#1862). At `sm` and up `inset-0` stays, as
  # `100vw` there would take in the page's scrollbar.
  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="kanban-modal fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-base-content/40 p-0 backdrop-blur-sm max-sm:h-dvh max-sm:w-screen sm:p-8"
      phx-window-keydown={@on_close}
      phx-key="Escape"
      phx-click-away={@on_close}
      phx-hook={@keys && "CardKeys"}
      data-card-keys={@keys && ""}
    >
      <div
        class={[
          "kanban-modal-in relative my-0 min-h-dvh w-full rounded-none bg-base-100 pb-[env(safe-area-inset-bottom)] shadow-2xl ring-1 ring-base-content/10 sm:my-4 sm:min-h-0 sm:rounded-2xl sm:pb-0",
          @size == "sm" && "max-w-md",
          @size == "md" && "max-w-xl",
          @size == "lg" && "max-w-4xl",
          @size == "xl" && "max-w-6xl",
          @size == "page" && "sm:max-w-[80%]",
          @size == "wide" && "sm:max-w-[90%]"
        ]}
        phx-click-away={@on_close}
      >
        <div class="modal-actions absolute right-3 top-3 z-10 flex items-center gap-2">
          {render_slot(@actions)}
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-circle"
            phx-click={@on_close}
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  ## Favourites -----------------------------------------------------------------

  attr :kind, :string,
    required: true,
    doc: ~s(what is being favourited: "board", "column", "card", "view" or "page")

  attr :id, :any, required: true, doc: "the thing's id"
  attr :name, :string, required: true, doc: "its name, for the label a screen reader reads"

  attr :marks, :any,
    required: true,
    doc: "the reader's favourites, from `Slipdock.Favourites.marks/1`"

  attr :class, :any, default: nil
  attr :size, :string, default: "size-4"

  @doc """
  The heart that puts something on `/favourites`, and takes it off again.

  A heart rather than a star because a card already *has* a star — the
  "Starred" flag, which is the board's and everyone's. This one is yours:
  nobody else's list changes when you press it, so it needs only the right
  to read the thing, not to change it.
  """
  def favourite_toggle(assigns) do
    {:ok, kind} = Slipdock.Favourites.kind(assigns.kind)
    marks = assigns.marks || MapSet.new()
    assigns = assign(assigns, on: Slipdock.Favourites.favourite?(marks, kind, assigns.id))

    ~H"""
    <button
      type="button"
      class={["shrink-0 transition", @class]}
      phx-click="toggle_favourite"
      phx-value-kind={@kind}
      phx-value-id={@id}
      aria-pressed={to_string(@on)}
      aria-label={"#{if @on, do: "Remove from", else: "Add to"} favourites: #{@name}"}
      title={
        if @on,
          do: "Remove from favourites",
          else: "Favourite: keep this two taps away, under Favourites"
      }
    >
      <.icon
        name={if @on, do: "hero-heart-solid", else: "hero-heart"}
        class={[
          @size,
          if(@on, do: "text-rose-500", else: "text-base-content/30 hover:text-rose-500")
        ]}
      />
    </button>
    """
  end

  ## Quick add -----------------------------------------------------------------

  @quick_add_help "Type a title and press Enter. Mix in commands: due: tomorrow · start: next mon · #high · #blocked · #todo (a list) · #tag · @name · ; a description · ;; a comment"

  attr :id, :string, required: true, doc: "the form id; the server clears the input by it"
  attr :placeholder, :string, default: "Add a card…"

  attr :params, :map,
    default: %{},
    doc: "hidden fields sent along (group, column_id, parent_card)"

  attr :preview, :any, default: nil, doc: "a Slipdock.QuickAdd result to show as chips"
  attr :class, :any, default: nil
  attr :style, :string, default: nil
  attr :autofocus, :boolean, default: false, doc: "focus the box when the row appears"

  @doc """
  A one-line add-a-card row: type, press Enter, type the next. Commands in
  the text (see `Slipdock.QuickAdd`) are previewed as chips while typing.
  """
  def quick_add_row(assigns) do
    assigns = assign(assigns, help: @quick_add_help)

    ~H"""
    <form
      id={@id}
      phx-submit="quick_add_card"
      phx-change="quick_add_change"
      class={["quick-add flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1", @class]}
      style={@style}
    >
      <input type="hidden" name="form" value={@id} />
      <input :for={{k, v} <- @params} type="hidden" name={k} value={v} />
      <.icon name="hero-plus" class="size-4 shrink-0 text-base-content/40" />
      <input
        type="text"
        name="title"
        id={"#{@id}-title"}
        phx-hook="QuickAdd"
        phx-debounce="150"
        phx-mounted={@autofocus && JS.focus()}
        placeholder={@placeholder}
        title={@help}
        class="input field-bare min-w-56 max-w-xl flex-1 px-1"
        autocomplete="off"
      />
      <.quick_chips :if={@preview} chips={@preview.chips} unknown={@preview.unknown} />
    </form>
    """
  end

  ## The board chrome shared with the wiki ------------------------------------
  @view_tabs [
    {:board, "", "Board", "hero-view-columns", "Board view", "b"},
    {:outline, "/outline", "Outline", "hero-queue-list",
     "Outline view: cards and their subcards as a tree", "o"},
    {:swimlanes, "/swimlanes", "Swimlanes", "hero-squares-2x2", "Swimlane view", "s"},
    {:table, "/table", "Table", "hero-table-cells", "Table view", "t"},
    {:timeline, "/timeline", "Timeline", "hero-chart-bar", "Timeline view", "i"},
    {:calendar, "/calendar", "Calendar", "hero-calendar-days", "Calendar view", "c"},
    {:narrative, "/narrative", "Narrative", "hero-book-open",
     "Narrative view: what happened to these cards over a date range", "n"},
    {:prioritise, "/prioritise", "Prioritise", "hero-scale",
     "Prioritise view: vote, score and rank the cards", "p"},
    {:visualise, "/visualise", "Visualise", "hero-presentation-chart-line",
     "Visualise: flow, velocity, runners and delivery on one page", "g"}
  ]

  # The views that are pages of their own rather than modes of the board
  # page, so they are navigated to, not patched.
  @page_views [:visualise]

  @doc false
  # The attribute, reachable from the helpers defined above it.
  def view_tabs_list, do: @view_tabs

  attr :board, :any, required: true
  attr :mode, :atom, required: true
  attr :view, :any, default: nil, doc: "the saved view currently loaded, if any"
  attr :marks, :any, default: nil, doc: "the reader's favourites (`Slipdock.Favourites.marks/1`)"

  # The view switcher that leads every board toolbar: the current view, with
  # the others in a menu, followed by the reader's own favourite saved views.
  def view_tabs(assigns) do
    # A simple board leaves its project-tooling views out of the menu.
    hidden = Slipdock.Boards.Board.hidden_views(assigns.board)
    tabs = Enum.reject(@view_tabs, fn {mode, _, _, _, _, _} -> Enum.member?(hidden, mode) end)

    # The wiki is not one of the card views, so it is not in the list; it
    # still has to name itself when it is what you are looking at.
    {_, _, label, icon, _, _} =
      case assigns.mode do
        :wiki ->
          {:wiki, "/wiki", "Wiki", "hero-book-open", "Wiki", nil}

        mode ->
          Enum.find(tabs, hd(tabs), fn {m, _, _, _, _, _} -> m == mode end)
      end

    marks = assigns.marks || MapSet.new()

    favourites =
      Enum.filter(assigns.board.saved_views, &Slipdock.Favourites.favourite?(marks, :view, &1.id))

    assigns =
      assign(assigns,
        tabs: tabs,
        label: label,
        icon: icon,
        favourites: favourites,
        page_views: @page_views
      )

    ~H"""
    <div id="view-menu" class="dropdown shrink-0" phx-hook="DropdownAlign">
      <div
        tabindex="0"
        role="button"
        class="btn btn-sm gap-1.5 bg-base-100 font-medium shadow-sm ring-1 ring-base-content/10"
        title="Switch view"
        aria-label={"View: #{@label}"}
      >
        <.icon name={@icon} class="size-4" />
        <span>{@label}</span>
        <.icon name="hero-chevron-down" class="size-3 text-base-content/50" />
      </div>
      <ul
        tabindex="0"
        class="menu dropdown-content z-40 mt-1 w-64 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
        role="group"
        aria-label="View mode"
      >
        <li :for={{mode, suffix, label, icon, title, key} <- @tabs}>
          <.link
            patch={mode not in @page_views && "/boards/#{@board.id}#{suffix}"}
            navigate={mode in @page_views && "/boards/#{@board.id}#{suffix}"}
            class={["flex items-center gap-2", @mode == mode && "menu-active"]}
            title={title}
            aria-current={@mode == mode && "page"}
          >
            <.icon name={icon} class="size-4 shrink-0" />
            <span class="flex-1">{label}</span>
            <kbd class="rounded border border-base-content/15 px-1 font-mono text-2xs text-base-content/50">
              {key}
            </kbd>
            <.icon :if={@mode == mode} name="hero-check" class="size-3.5" />
          </.link>
        </li>
        <%!-- The wiki is not a view of the cards, so it sits below the line:
              same board, different kind of thing. --%>
        <li class="mt-1 border-t border-base-content/10 pt-1">
          <.link
            navigate={~p"/boards/#{@board.id}/wiki"}
            class={["flex items-center gap-2", @mode == :wiki && "menu-active"]}
            title="Wiki: the board's documents"
            aria-current={@mode == :wiki && "page"}
          >
            <.icon name="hero-book-open" class="size-4 shrink-0" />
            <span class="flex-1">Wiki</span>
            <.icon :if={@mode == :wiki} name="hero-check" class="size-3.5" />
          </.link>
        </li>
        <li :if={@favourites != []} class="menu-title mt-1 border-t border-base-content/10 pt-2">
          Favourite views
        </li>
        <%!-- `SlipdockWeb.SwimlaneComponents` imports this module, so reaching
              back for `view_path/2` is a remote call rather than an import:
              importing it makes the two deadlock at compile time. --%>
        <li :for={v <- @favourites}>
          <.link
            patch={SlipdockWeb.SwimlaneComponents.view_path(@board, v)}
            class={["flex items-center gap-2", @view && @view.id == v.id && "menu-active"]}
            title={"Open the “#{v.name}” view"}
            aria-current={@view && @view.id == v.id && "page"}
          >
            <.icon name="hero-heart-solid" class="size-4 shrink-0 text-rose-500" />
            <span class="min-w-0 flex-1 truncate">{v.name}</span>
            <.icon :if={@view && @view.id == v.id} name="hero-check" class="size-3.5" />
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :filters, :map, required: true
  attr :filtering, :boolean, required: true
  attr :label, :string, default: "Hide completed cards"

  attr :kinds, :boolean,
    default: true,
    doc: "Offer the Kind section. False where everything in view is the one kind."

  attr :states, :boolean,
    default: false,
    doc: """
    Offer the filters that read a card's state (#1117): Stuck, and Agent /
    Human on a tree with a runner rule. Cards only; a page has no state.
    """

  @doc """
  The filter dropdown the card views carry, and the wiki carries too: a wiki
  page answers every one of these, because it holds the card's facets under
  the card's names (see `Slipdock.Filters`).
  """
  def filter_menu(assigns) do
    ~H"""
    <div class="dropdown">
      <div
        tabindex="0"
        role="button"
        class={["btn btn-ghost btn-sm gap-1", @filtering && "text-primary"]}
        title="Filter"
      >
        <.icon name="hero-funnel" class="size-4" />
        <span class="hidden md:inline">Filter</span>
        <span :if={@filtering} class="badge badge-primary badge-xs">
          {Slipdock.Filters.count(@filters)}
        </span>
      </div>
      <div
        tabindex="0"
        class="dropdown-content z-30 mt-2 w-72 space-y-4 rounded-2xl bg-base-100 p-4 shadow-xl ring-1 ring-base-content/10"
      >
        <%!-- The three things a list can hold: a card, a document (a card whose
              whole content is the file on it) and a wiki page placed in the
              list. See `Slipdock.Kinds`. --%>
        <div :if={@kinds}>
          <p class="mb-1.5 section-label">
            Kind
          </p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={{kind, label} <- Slipdock.Kinds.all()}
              type="button"
              class={[
                "btn btn-xs",
                if(kind in @filters.kinds, do: "btn-primary", else: "btn-ghost")
              ]}
              phx-click="filter_kind"
              phx-value-kind={kind}
              title={"Show #{String.downcase(label)}"}
            >
              <.icon name={kind_icon(kind)} class="size-3.5" /> {label}
            </button>
          </div>
        </div>
        <div :if={@board.tags != []}>
          <p class="mb-1.5 section-label">
            Tags
          </p>
          <div class="flex flex-wrap gap-1.5">
            <button
              :for={tag <- @board.tags}
              type="button"
              class={[
                "rounded-md ring-2 ring-offset-1 ring-offset-base-100 transition",
                if(tag.id in @filters.tags,
                  do: "ring-primary",
                  else: "ring-transparent opacity-80 hover:opacity-100"
                )
              ]}
              phx-click="filter_tag"
              phx-value-id={tag.id}
            >
              <.tag_chip tag={tag} />
            </button>
          </div>
        </div>
        <div>
          <p class="mb-1.5 section-label">
            Priority
          </p>
          <div class="flex flex-wrap gap-1" data-role="filter-priority">
            <button
              :for={p <- ~w(low medium high critical)}
              type="button"
              class={["btn btn-xs", if(@filters.priority == p, do: "btn-primary", else: "btn-ghost")]}
              phx-click="filter_priority"
              phx-value-priority={p}
            >
              <.priority_badge priority={p} /> {priority_label(p)}
            </button>
          </div>
        </div>
        <div>
          <p class="mb-1.5 section-label">
            Flags
          </p>
          <div class="flex flex-wrap gap-1">
            <.flag_toggle
              :for={{flag, _, _, _, _} <- flags()}
              flag={flag}
              active={@filters.flag == flag}
              phx-click="filter_flag"
              phx-value-flag={flag}
            />
          </div>
        </div>
        <div>
          <p class="mb-1.5 flex items-center gap-1 section-label" data-role="filter-due">
            <.icon name={due_icon()} class="size-3.5" /> Due
          </p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={
                {value, label} <- [
                  {"overdue", "Overdue"},
                  {"week", "Next 7 days"},
                  {"none", "No date"}
                ]
              }
              type="button"
              class={["btn btn-xs", if(@filters.due == value, do: "btn-primary", else: "btn-ghost")]}
              phx-click="filter_due"
              phx-value-due={value}
            >
              {label}
            </button>
          </div>
        </div>
        <div :if={@states}>
          <p class="mb-1.5 section-label">
            Time in list
          </p>
          <button
            type="button"
            class={["btn btn-xs", if(@filters.stuck, do: "btn-primary", else: "btn-ghost")]}
            phx-click="filter_stuck"
            title="Cards in their list longer than it usually takes"
          >
            <.icon name="hero-clock" class="size-3.5" /> Stuck
          </button>
        </div>
        <div :if={@states and @board.runner_tree}>
          <p class="mb-1.5 section-label">
            Driver
          </p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={{value, label} <- Slipdock.Swimlanes.Config.drivers()}
              type="button"
              class={[
                "btn btn-xs",
                if((@filters.driver || "all") == value, do: "btn-primary", else: "btn-ghost")
              ]}
              phx-click="filter_driver"
              phx-value-driver={value}
            >
              {label}
            </button>
          </div>
        </div>
        <div :if={@states} data-role="origin-filter">
          <p class="mb-1.5 section-label">
            Origin
          </p>
          <div class="flex flex-wrap gap-1">
            <button
              :for={{value, label} <- Slipdock.Origin.buckets()}
              type="button"
              class={[
                "btn btn-xs",
                if(Map.get(@filters, :origin) == value, do: "btn-primary", else: "btn-ghost")
              ]}
              phx-click="filter_origin"
              phx-value-origin={value}
            >
              {label}
            </button>
          </div>
        </div>
        <label class="flex cursor-pointer items-center gap-2 text-sm">
          <input
            type="checkbox"
            class="toggle"
            checked={@filters.hide_completed}
            phx-click="toggle_hide_completed"
          /> {@label}
        </label>
        <button
          :if={@filtering}
          type="button"
          class="btn btn-ghost btn-xs w-full"
          phx-click="clear_filters"
        >
          Clear all filters
        </button>
      </div>
    </div>
    """
  end

  ## Support access --------------------------------------------------------

  attr :id, :string, required: true
  attr :boards, :list, required: true

  @doc """
  The boards a support session opens, as links: the way in to what the
  session grants, which no board list shows (see `Slipdock.Access.supported_boards/1`).
  """
  def support_board_links(assigns) do
    ~H"""
    <p :if={@boards == []} id={@id} class="text-xs text-base-content/60">
      They have no boards of their own.
    </p>
    <ul :if={@boards != []} id={@id} class="flex flex-wrap gap-1.5">
      <li :for={board <- @boards}>
        <.link
          navigate={~p"/boards/#{board}"}
          id={"#{@id}-#{board.id}"}
          class="flex items-center gap-1.5 rounded-lg bg-base-100 px-2 py-1 text-xs font-medium ring-1 ring-base-content/10 hover:ring-primary/40"
        >
          <span class={["size-2 shrink-0 rounded-full", Palette.dot(board.color)]}></span>
          {board.name}
          <span :if={board.code} class="font-mono text-2xs text-base-content/50">{board.code}</span>
        </.link>
      </li>
    </ul>
    """
  end

  @doc "How long a support session has left, as \"3h 52m\"."
  def support_time_left(%DateTime{} = expires_at, now \\ DateTime.utc_now()) do
    minutes = max(DateTime.diff(expires_at, now, :minute), 0)

    case {div(minutes, 60), rem(minutes, 60)} do
      {0, m} -> "#{m}m"
      {h, 0} -> "#{h}h"
      {h, m} -> "#{h}h #{m}m"
    end
  end

  @doc """
  A board's handles as a tooltip (#1716): its code (for the CLI and
  `[[links]]`), its switcher key (b, then it) and the reader's own
  Ctrl+Shift digit, after an optional first line (the description, say).
  The board name carries this as its `title` rather than drawing the
  handles as chips beside it. One line each: "Code: kbe2e",
  "Switcher: b then k".
  """
  def board_handles_title(board, lead \\ nil, hotkey \\ nil) do
    [
      lead,
      Map.get(board, :code) && "Code: #{board.code}",
      Map.get(board, :shortcut) && "Switcher: b then #{board.shortcut}",
      hotkey && "Ctrl+Shift+#{hotkey} opens it from any page"
    ]
    |> Enum.reject(&Enum.member?([nil, ""], &1))
    |> Enum.join("\n")
  end
end

defmodule SlipdockWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SlipdockWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil
  attr :current_user, :any, default: nil

  attr :alerts, :list,
    default: nil,
    doc: "alerts raised by automation rules (see SlipdockWeb.AlertsHook); nil hides the section"

  attr :alerts_open, :boolean, default: false, doc: "whether the alerts section is expanded"

  attr :quick_add, :map,
    default: nil,
    doc: "the quick add box's state (see SlipdockWeb.QuickAddHook); nil hides it"

  attr :shortcuts, :map,
    default: nil,
    doc: "the keyboard shortcut state (see SlipdockWeb.ShortcutsHook); nil turns the keys off"

  attr :page_jumps, :list,
    default: [],
    doc: "places on this page the \"v\" key can jump to: %{key, label, icon, patch}"

  attr :viewport, :integer,
    default: nil,
    doc: "the window width the server last heard about (see SlipdockWeb.ViewportHook)"

  attr :nav_active, :atom,
    default: nil,
    doc:
      "which place in the navigation this page is: :boards, :wiki, :work, :favourites, :search or :ask"

  slot :inner_block, required: true
  slot :nav, doc: "content rendered in the header next to the brand"
  slot :actions, doc: "content rendered on the right side of the header"

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col bg-base-200">
      <header class="flex h-12 shrink-0 items-center gap-2 border-b border-base-300 bg-base-100 px-3 sm:gap-3 sm:px-4">
        <.link
          navigate={~p"/"}
          class="flex shrink-0 items-center gap-2 rounded-lg px-1.5 py-1 font-semibold tracking-tight hover:bg-base-200"
        >
          <.brand_mark />
          <.brand_wordmark class="hidden h-4 sm:inline-flex" />
        </.link>
        <div class="flex min-w-0 flex-1 items-center gap-2">
          {render_slot(@nav)}
        </div>
        <div class="flex shrink-0 items-center gap-1">
          {render_slot(@actions)}
          <%!-- Ctrl-O and Ctrl-P on a desktop; on a phone there is no Ctrl, and
                the card finder is the fastest way to a card on a screen that
                shows one list at a time. Same two panels, same two events. --%>
          <button
            :if={@shortcuts}
            type="button"
            phx-click="shortcut_panel"
            phx-value-panel="find"
            class="btn btn-ghost btn-sm btn-square sm:hidden"
            aria-label="Find a card"
            title="Find a card"
          >
            <.icon name="hero-magnifying-glass" class="size-5" />
          </button>
          <button
            :if={@shortcuts}
            type="button"
            phx-click="shortcut_panel"
            phx-value-panel="command"
            class="btn btn-ghost btn-sm btn-square sm:hidden"
            aria-label="Commands"
            title="Commands"
          >
            <.icon name="hero-command-line" class="size-5" />
          </button>
          <%!-- Deep search and Ask are two halves of the same thing — find it
                yourself, or have the assistant find it and answer — so they sit
                together, left of the heart. The magnifying glass beside them on
                a phone is the card finder, which is a different job: that one
                jumps to a card you can already name. --%>
          <.link
            :if={@current_user}
            id="search-link"
            navigate={~p"/search"}
            aria-current={@nav_active == :search && "page"}
            class={[
              "btn btn-ghost btn-sm btn-square hidden sm:inline-flex",
              @nav_active == :search && "bg-base-200 text-primary"
            ]}
            aria-label="Search everything"
            title="Search everything"
          >
            <.icon name="hero-magnifying-glass-circle" class="size-4" />
          </.link>
          <.link
            :if={@current_user}
            id="ask-link"
            navigate={~p"/ask"}
            aria-current={@nav_active == :ask && "page"}
            class={[
              "btn btn-ghost btn-sm btn-square hidden sm:inline-flex",
              @nav_active == :ask && "bg-base-200 text-primary"
            ]}
            aria-label="Ask about everything"
            title="Ask about everything"
          >
            <.icon name="hero-sparkles" class="size-4" />
          </.link>
          <%!-- The phone keeps Favourites in its bottom bar; on a desktop the
                heart sits here, so the handful of things you go back to all day
                are one click rather than a hunt through the avatar menu, which
                keeps its own entry for the times the header is not on screen. --%>
          <.link
            :if={@current_user}
            id="favourites-link"
            navigate={~p"/favourites"}
            aria-current={@nav_active == :favourites && "page"}
            class={[
              "btn btn-ghost btn-sm btn-square hidden sm:inline-flex",
              @nav_active == :favourites && "bg-base-200 text-primary"
            ]}
            aria-label="Favourites"
            title="Favourites"
          >
            <.icon name="hero-heart" class="size-4" />
          </.link>
          <.quick_add_bar :if={@quick_add} quick_add={@quick_add} />
          <.alerts_bar :if={@alerts} alerts={@alerts} open={@alerts_open} />
          <.theme_toggle :if={!@current_user} />
          <div :if={@current_user} class="dropdown dropdown-end ml-1">
            <div
              tabindex="0"
              role="button"
              class="flex size-8 cursor-pointer items-center justify-center rounded-full bg-primary/15 text-xs font-bold text-primary"
              title={Slipdock.Accounts.User.display_name(@current_user)}
            >
              {Slipdock.Accounts.User.initials(@current_user)}
            </div>
            <ul
              tabindex="0"
              class="menu dropdown-content z-40 mt-2 w-60 rounded-box bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
            >
              <li class="menu-title truncate">
                {Slipdock.Accounts.User.display_name(@current_user)}
              </li>
              <li>
                <.link navigate={~p"/"}><.icon name="hero-view-columns" class="size-4" /> Boards</.link>
              </li>
              <li>
                <.link navigate={~p"/work"}><.icon name="hero-user" class="size-4" /> My work</.link>
              </li>
              <li>
                <.link navigate={~p"/wiki"}><.icon name="hero-book-open" class="size-4" /> Wiki</.link>
              </li>
              <li>
                <.link navigate={~p"/search"}><.icon
                  name="hero-magnifying-glass-circle"
                  class="size-4"
                /> Search everything</.link>
              </li>
              <li>
                <.link navigate={~p"/ask"}><.icon name="hero-sparkles" class="size-4" /> Ask</.link>
              </li>
              <li>
                <.link navigate={~p"/groups"}><.icon name="hero-user-group" class="size-4" /> Groups</.link>
              </li>
              <li>
                <.link navigate={~p"/favourites"}><.icon name="hero-heart" class="size-4" />
                Favourites</.link>
              </li>
              <li>
                <.link navigate={~p"/templates"}><.icon name="hero-squares-plus" class="size-4" />
                Templates</.link>
              </li>
              <li>
                <.link navigate={~p"/account"}><.icon name="hero-user-circle" class="size-4" />
                Account &amp; API tokens</.link>
              </li>
              <li :if={Slipdock.Accounts.admin?(@current_user)}>
                <.link navigate={~p"/users"}>
                  <.icon name="hero-users" class="size-4" /> Users
                  <span :if={waiting_signups() > 0} class="badge badge-sm badge-warning">
                    {waiting_signups()}
                  </span>
                </.link>
              </li>
              <li :if={Slipdock.Accounts.admin?(@current_user)}>
                <.link navigate={~p"/config"}>
                  <.icon name="hero-wrench-screwdriver" class="size-4" /> Configuration
                </.link>
              </li>
              <li class="menu-title mt-1">Theme</li>
              <li><.theme_item theme="system" icon="hero-computer-desktop" label="System" /></li>
              <li><.theme_item theme="light" icon="hero-sun" label="Light" /></li>
              <li><.theme_item theme="dark" icon="hero-moon" label="Dark" /></li>
              <li class="mt-1 border-t border-base-300/60 pt-1">
                <.link href={~p"/logout"} method="delete"><.icon
                  name="hero-arrow-right-start-on-rectangle"
                  class="size-4"
                /> Sign out</.link>
              </li>
            </ul>
          </div>
        </div>
      </header>

      <main class="min-h-0 flex-1">
        {render_slot(@inner_block)}
      </main>

      <.mobile_bar
        :if={@current_user}
        active={@nav_active}
        quick_add={@quick_add}
        alerts={@alerts}
        alerts_open={@alerts_open}
      />

      <div id="viewport" phx-hook="Viewport" data-width={@viewport} class="hidden"></div>

      <div
        :if={@shortcuts}
        id="keys"
        phx-hook="Keys"
        data-views={to_string(@page_jumps != [])}
        class="hidden"
      >
      </div>
      <.shortcut_palette
        :if={@shortcuts && @shortcuts.panel}
        shortcuts={@shortcuts}
        jumps={@page_jumps}
      />

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :active, :atom, default: nil
  attr :quick_add, :map, default: nil
  attr :alerts, :list, default: nil
  attr :alerts_open, :boolean, default: false

  @doc """
  The phone's bottom bar: the app's five places, within reach of a thumb.

  On a desktop this navigation lives in the avatar menu and the header — two
  taps up in the far corner, which on a phone is both a stretch and a hunt.
  Down here Boards, My work, Favourites and Alerts are one tap, and **Add**
  sits in the middle where the thumb already rests, because putting a card
  somewhere is the thing people open this app on a phone to do.

  It is a sibling of `<main>` in the page's flex column, not an overlay, so
  content is never hidden underneath it, and it carries the home indicator's
  safe area as padding of its own.
  """
  def mobile_bar(assigns) do
    ~H"""
    <nav
      id="mobile-bar"
      aria-label="Main"
      class="shrink-0 border-t border-base-300 bg-base-100 pb-[env(safe-area-inset-bottom)] sm:hidden"
    >
      <div class="flex h-[3.75rem] items-stretch justify-around px-1">
        <.mobile_tab
          navigate={~p"/"}
          icon="hero-view-columns"
          label="Boards"
          on={@active == :boards}
        />
        <.mobile_tab navigate={~p"/work"} icon="hero-user" label="My work" on={@active == :work} />

        <button
          :if={@quick_add}
          type="button"
          id="quick-add-fab"
          phx-click="toggle_quick_add"
          aria-expanded={to_string(@quick_add.open?)}
          aria-controls="quick-add-panel"
          class="flex w-16 shrink-0 flex-col items-center justify-center gap-1"
          aria-label="Quick add a card"
        >
          <span class={[
            "flex size-9 items-center justify-center rounded-full shadow-sm transition-colors",
            if(@quick_add.open?,
              do: "bg-primary text-primary-content",
              else: "bg-primary/15 text-primary"
            )
          ]}>
            <.icon name="hero-plus" class="size-5" />
          </span>
          <span class="text-[0.625rem] font-medium leading-none text-primary">Add</span>
        </button>

        <button
          :if={@alerts}
          type="button"
          phx-click="toggle_alerts"
          aria-expanded={to_string(@alerts_open)}
          aria-controls="alerts-panel"
          class={[
            "flex w-16 shrink-0 flex-col items-center justify-center gap-1",
            if(@alerts_open, do: "text-primary", else: "text-base-content/60")
          ]}
        >
          <span class="relative flex">
            <.icon name="hero-bell" class="size-5" />
            <span
              :if={@alerts != []}
              class={[
                "absolute -right-2 -top-1 min-w-4 rounded-full px-1 text-[0.625rem] font-semibold leading-4",
                alert_tint(@alerts)
              ]}
            >
              {length(@alerts)}
            </span>
          </span>
          <span class="text-[0.625rem] font-medium leading-none">Alerts</span>
        </button>

        <%!-- Templates had this slot, and a template is something you reach for
              when making a board — which is rare. A favourite is something you
              reach for all day. Templates keep their place in the avatar menu. --%>
        <.mobile_tab
          navigate={~p"/favourites"}
          icon="hero-heart"
          label="Favourites"
          on={@active == :favourites}
        />
      </div>
    </nav>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :on, :boolean, default: false

  defp mobile_tab(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@on && "page"}
      class={[
        "flex w-16 shrink-0 flex-col items-center justify-center gap-1",
        if(@on, do: "text-primary", else: "text-base-content/60")
      ]}
    >
      <.icon name={@icon} class="size-5" />
      <span class="text-[0.625rem] font-medium leading-none">{@label}</span>
    </.link>
    """
  end

  # The badge takes the colour of the worst alert waiting.
  defp alert_tint(alerts) do
    cond do
      Enum.any?(alerts, &(&1.severity == "urgent")) -> "bg-error text-error-content"
      Enum.any?(alerts, &(&1.severity == "warning")) -> "bg-warning text-warning-content"
      true -> "bg-info text-info-content"
    end
  end

  attr :shortcuts, :map, required: true
  attr :jumps, :list, required: true

  @doc """
  The panel the `b`, `v`, `?`, `Ctrl-P` and `Ctrl-O` keys open.

  Two kinds share the one frame. The first three are *keyed*: a list of things
  each carrying its own key, which the `Keys` hook narrows as you type and
  clicks when you finish one. The last two are *filtered*: you type what you
  are after, the server says what matched, and the arrows and Enter walk the
  answer. `data-key-capture` says which kind is up, so the hook knows whether
  a letter is a key or a letter.

  Either way every row is an ordinary link or button, and works just as well
  with the mouse.
  """
  def shortcut_palette(assigns) do
    ~H"""
    <div
      id="key-palette"
      data-key-capture={if @shortcuts.panel in [:command, :find], do: "filter", else: "keys"}
      phx-click-away={JS.push("close_shortcuts")}
      phx-window-keydown={JS.push("close_shortcuts")}
      phx-key="Escape"
      class="fixed inset-0 z-[70] flex items-start justify-center overflow-y-auto bg-base-content/30 p-3 pt-[5vh] backdrop-blur-sm sm:p-4 sm:pt-[10vh]"
    >
      <div class="kanban-modal-in w-full max-w-lg overflow-hidden rounded-2xl bg-base-100 shadow-2xl ring-1 ring-base-content/10">
        <header class="flex items-center gap-2 border-b border-base-300/70 px-4 py-2.5 text-sm font-semibold">
          <.icon name={panel_icon(@shortcuts.panel)} class="size-4 text-base-content/50" />
          {panel_title(@shortcuts.panel)}
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-circle ml-auto"
            phx-click={JS.push("close_shortcuts")}
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>

        <ul :if={@shortcuts.panel == :boards} class="max-h-[60vh] overflow-y-auto p-1.5">
          <li :for={board <- @shortcuts.boards}>
            <.link
              navigate={~p"/boards/#{board}"}
              data-shortcut={board.shortcut}
              class="flex items-center gap-2.5 rounded-lg px-2 py-1.5 text-sm hover:bg-base-200"
            >
              <.palette_key key={board.shortcut} />
              <span class={["size-2.5 shrink-0 rounded-full", Slipdock.Palette.dot(board.color)]}></span>
              <span class="min-w-0 flex-1 truncate">{board.name}</span>
              <span class="chip chip-line shrink-0 font-mono text-2xs">{board.code}</span>
            </.link>
          </li>
          <li :if={@shortcuts.boards == []} class="px-3 py-6 text-center text-sm text-base-content/50">
            No boards yet.
          </li>
        </ul>

        <ul :if={@shortcuts.panel == :views} class="max-h-[60vh] overflow-y-auto p-1.5">
          <li :for={jump <- @jumps}>
            <.link
              patch={jump.patch}
              data-shortcut={jump.key}
              class={[
                "flex items-center gap-2.5 rounded-lg px-2 py-1.5 text-sm hover:bg-base-200",
                jump[:current] && "bg-base-200/70 font-medium"
              ]}
            >
              <.palette_key key={jump.key} />
              <.icon name={jump.icon} class="size-4 shrink-0 text-base-content/60" />
              <span class="min-w-0 flex-1 truncate">{jump.label}</span>
              <.icon :if={jump[:current]} name="hero-check" class="size-3.5 shrink-0" />
            </.link>
          </li>
        </ul>

        <div
          :if={@shortcuts.panel == :help}
          class="max-h-[70vh] space-y-4 overflow-y-auto px-4 py-3.5"
        >
          <section :for={{section, keys} <- SlipdockWeb.Shortcuts.sections()} class="space-y-1">
            <h3 class="text-2xs font-semibold uppercase tracking-wide text-base-content/45">
              {section}
            </h3>
            <dl class="space-y-0.5">
              <div :for={{key, what} <- keys} class="flex items-baseline gap-2.5 text-sm">
                <dt class="w-24 shrink-0 text-right">
                  <kbd class="rounded border border-base-content/20 bg-base-200/60 px-1.5 py-0.5 font-mono text-2xs">
                    {key}
                  </kbd>
                </dt>
                <dd class="min-w-0 flex-1 text-base-content/70">{what}</dd>
              </div>
            </dl>
          </section>
        </div>

        <div :if={@shortcuts.panel in [:command, :find]}>
          <form
            id="palette-form"
            phx-change="palette_filter"
            phx-submit="palette_filter"
            class="px-3 pt-3"
          >
            <input
              type="text"
              id={"palette-q-#{@shortcuts.panel}"}
              name="q"
              value={@shortcuts.query}
              phx-hook="Focus"
              data-select
              autocomplete="off"
              phx-debounce={if @shortcuts.panel == :find, do: "150"}
              placeholder={
                if @shortcuts.panel == :find,
                  do: "Type a card's title…",
                  else: "Type a command, a board, a page…"
              }
              class="input input-sm w-full"
            />
          </form>

          <ul id="palette-rows" phx-hook="PaletteCursor" class="max-h-[55vh] overflow-y-auto p-1.5">
            <li :for={{row, i} <- Enum.with_index(@shortcuts.results)}>
              <.palette_row
                row={row}
                panel={@shortcuts.panel}
                on={i == @shortcuts.cursor}
                group={group_of(row) != group_of(Enum.at(@shortcuts.results, i - 1)) or i == 0}
              />
            </li>
            <li
              :if={@shortcuts.results == []}
              class="px-3 py-6 text-center text-sm text-base-content/50"
            >
              {empty_palette(@shortcuts)}
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :row, :any, required: true
  attr :panel, :atom, required: true
  attr :on, :boolean, required: true
  attr :group, :boolean, default: false

  # One row of a filtered palette: a command to follow, or a card to open.
  defp palette_row(%{panel: :find} = assigns) do
    ~H"""
    <.link
      navigate={~p"/boards/#{@row.board_id}/cards/#{@row.id}"}
      data-row
      data-on={@on && ""}
      class={[
        "flex items-center gap-2.5 rounded-lg px-2 py-1.5 text-sm hover:bg-base-200",
        @on && "bg-base-200"
      ]}
    >
      <.icon
        name={if @row.completed, do: "hero-check-circle", else: "hero-rectangle-stack"}
        class="size-4 shrink-0 text-base-content/50"
      />
      <span class={["min-w-0 flex-1 truncate", @row.completed && "text-base-content/50 line-through"]}>
        {@row.title}
      </span>
      <span class="shrink-0 text-2xs text-base-content/50">{@row.board.name}</span>
    </.link>
    """
  end

  # A command that does something: a button, closing the palette on the way
  # past so the row feels like a command rather than a switch left sitting.
  defp palette_row(%{row: %{to: {:event, event, params}}} = assigns) do
    assigns = assign(assigns, :click, JS.push("close_shortcuts") |> JS.push(event, value: params))

    ~H"""
    <.palette_group :if={@group} label={@row.group} />
    <button
      type="button"
      phx-click={@click}
      data-row
      data-on={@on && ""}
      class={row_class(@row, @on)}
    >
      <.palette_command row={@row} />
    </button>
    """
  end

  # A command that goes somewhere: an ordinary link, of whichever kind.
  defp palette_row(assigns) do
    assigns = assign(assigns, :to, link_attrs(assigns.row))

    ~H"""
    <.palette_group :if={@group} label={@row.group} />
    <.link {@to} data-row data-on={@on && ""} class={row_class(@row, @on)}>
      <.palette_command row={@row} />
    </.link>
    """
  end

  defp link_attrs(%{to: {:navigate, path}}), do: %{navigate: path}
  defp link_attrs(%{to: {:patch, path}}), do: %{patch: path}
  defp link_attrs(%{to: {:href, path, method}}), do: %{href: path, method: method}

  defp row_class(row, on) do
    [
      "flex w-full items-center gap-2.5 rounded-lg px-2 py-1.5 text-left text-sm hover:bg-base-200",
      on && "bg-base-200",
      row[:current] && "font-medium"
    ]
  end

  attr :label, :string, required: true

  defp palette_group(assigns) do
    ~H"""
    <div class="px-2 pb-0.5 pt-2 text-2xs font-semibold uppercase tracking-wide text-base-content/40">
      {@label}
    </div>
    """
  end

  attr :row, :map, required: true

  defp palette_command(assigns) do
    ~H"""
    <.icon name={@row.icon} class="size-4 shrink-0 text-base-content/60" />
    <span class="min-w-0 flex-1 truncate">{@row.label}</span>
    <kbd
      :if={@row[:key]}
      class="shrink-0 rounded border border-base-content/20 bg-base-200/60 px-1.5 py-0.5 font-mono text-2xs"
    >
      {@row.key}
    </kbd>
    """
  end

  # Cards have no group; commands do, and a change of it starts a new heading.
  defp group_of(%{group: group}), do: group
  defp group_of(_), do: nil

  defp empty_palette(%{panel: :find, query: ""}), do: "Type to find a card on any board."
  defp empty_palette(%{panel: :find}), do: "No cards match."
  defp empty_palette(_), do: "No commands match."

  attr :key, :string, default: nil

  defp palette_key(assigns) do
    ~H"""
    <kbd class={[
      "flex size-5 shrink-0 items-center justify-center rounded border font-mono text-2xs",
      if(@key,
        do: "border-base-content/20 bg-base-200/60",
        else: "border-transparent text-base-content/25"
      )
    ]}>
      {@key || "—"}
    </kbd>
    """
  end

  defp panel_title(:boards), do: "Switch board"
  defp panel_title(:views), do: "Switch view"
  defp panel_title(:help), do: "Keyboard shortcuts"
  defp panel_title(:command), do: "Commands"
  defp panel_title(:find), do: "Find a card"

  defp panel_icon(:boards), do: "hero-view-columns"
  defp panel_icon(:views), do: "hero-rectangle-group"
  defp panel_icon(:help), do: "hero-command-line"
  defp panel_icon(:command), do: "hero-chevron-right"
  defp panel_icon(:find), do: "hero-magnifying-glass"

  attr :quick_add, :map, required: true

  @doc """
  The quick add section of the header bar: a box to tap, opening a one-line
  form that puts a card on the default board and list (both set in Account
  settings). The line itself is read by `Slipdock.QuickAdd.Capture`, which
  lifts out the dates, priority, flags, tags, assignee, and the board or
  list when the line names one.

  Both the form and its input are named by `form_key`, which the hook bumps
  after each card is added: a new id makes the browser build a fresh, empty
  input rather than keep the focused one (LiveView never patches the value
  of the field you are typing in), and `phx-mounted` puts the cursor back —
  cleared and ready for the next line.
  """
  def quick_add_bar(assigns) do
    ~H"""
    <div class="relative contents sm:block" id="quick-add" phx-hook="QuickAddKey">
      <button
        type="button"
        id="quick-add-open"
        phx-click="toggle_quick_add"
        aria-expanded={to_string(@quick_add.open?)}
        aria-controls="quick-add-panel"
        title="Quick add a card (press q)"
        class={[
          "hidden items-center gap-2 rounded-full py-1.5 pl-2.5 pr-2 text-xs transition-colors sm:flex",
          "bg-base-200/70 text-base-content/60 hover:bg-base-200 hover:text-base-content",
          @quick_add.open? && "bg-base-200 text-base-content"
        ]}
      >
        <.icon name="hero-plus" class="size-3.5" />
        <span class="pr-6">Quick add…</span>
        <kbd class="rounded border border-base-content/15 px-1 font-mono text-2xs">q</kbd>
      </button>
      <div
        :if={@quick_add.open?}
        id="quick-add-panel"
        phx-click-away={JS.push("toggle_quick_add")}
        phx-window-keydown={JS.push("toggle_quick_add")}
        phx-key="Escape"
        class={[
          "kanban-modal-in z-50 overflow-hidden rounded-box bg-base-100 shadow-xl ring-1 ring-base-content/10",
          "fixed inset-x-2 top-[3.25rem]",
          "sm:absolute sm:inset-x-auto sm:right-0 sm:top-full sm:mt-1.5 sm:w-[min(30rem,calc(100vw-1rem))]"
        ]}
      >
        <form
          id={"quick-add-form-#{@quick_add.form_key}"}
          phx-submit="quick_add_submit"
          class="flex items-center gap-2 border-b border-base-300/70 px-3 py-2.5"
        >
          <.icon
            :if={!@quick_add.busy?}
            name={if @quick_add.ai?, do: "hero-sparkles", else: "hero-plus"}
            class="size-4 shrink-0 text-base-content/40"
          />
          <.icon
            :if={@quick_add.busy?}
            name="hero-arrow-path"
            class="size-4 shrink-0 text-primary motion-safe:animate-spin"
          />
          <input
            type="text"
            name="text"
            id={"quick-add-input-#{@quick_add.form_key}"}
            value={@quick_add.text}
            phx-mounted={JS.focus()}
            readonly={@quick_add.busy?}
            placeholder={quick_add_placeholder(@quick_add)}
            class="input input-sm input-ghost min-w-0 flex-1 px-1"
            autocomplete="off"
          />
          <button type="submit" class="btn btn-primary btn-xs" disabled={@quick_add.busy?}>
            Add
          </button>
        </form>

        <p :if={@quick_add.destination} class="px-3 py-2 text-2xs text-base-content/50">
          Goes to
          <span class="font-medium text-base-content/70">{elem(@quick_add.destination, 0)}</span>
          › <span class="font-medium text-base-content/70">{elem(@quick_add.destination, 1)}</span>
          unless the line says otherwise.
          <.link navigate={~p"/account"} class="link link-hover text-primary">Change</.link>
        </p>
        <p :if={is_nil(@quick_add.destination)} class="px-3 py-2 text-2xs text-warning">
          You have no board to add to yet — make one first.
        </p>

        <div :if={@quick_add.error} class="border-t border-base-300/70 px-3 py-2 text-xs text-error">
          {@quick_add.error}
        </div>

        <div :if={@quick_add.result} class="border-t border-base-300/70 bg-base-200/40 px-3 py-2.5">
          <div class="flex items-start gap-2">
            <.icon name="hero-check-circle" class="mt-0.5 size-4 shrink-0 text-success" />
            <div class="min-w-0 flex-1">
              <.link
                navigate={
                  ~p"/boards/#{@quick_add.result.board.id}/cards/#{@quick_add.result.card.id}"
                }
                class="block truncate text-sm font-medium hover:underline"
              >
                {@quick_add.result.card.title}
              </.link>
              <p class="mt-0.5 text-2xs text-base-content/50">
                added to {@quick_add.result.board.name} › {@quick_add.result.column.name}
              </p>
              <.quick_chips
                :if={@quick_add.result.chips != []}
                chips={@quick_add.result.chips}
                class="mt-1.5"
              />
              <p
                :for={note <- @quick_add.result.notes}
                class="mt-1 text-2xs italic text-base-content/50"
              >
                {note}
              </p>
            </div>
            <button
              type="button"
              class="btn btn-ghost btn-xs btn-square opacity-40 hover:opacity-100"
              phx-click="quick_add_dismiss"
              aria-label="Dismiss"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp quick_add_placeholder(%{ai?: true}), do: "Call the printers about banners, friday, urgent"
  defp quick_add_placeholder(_), do: "Write the launch post due: friday #high"

  attr :alerts, :list, required: true
  attr :open, :boolean, default: false

  @doc """
  The alerts section of the header bar: always there, collapsed to a count,
  expanding into the list of alerts automation rules have raised. Each one
  is dismissed by the person reading it; other people keep theirs.
  """
  def alerts_bar(assigns) do
    assigns =
      assign(assigns,
        count: length(assigns.alerts),
        worst:
          Enum.find_value(
            ~w(urgent warning),
            &if(Enum.any?(assigns.alerts, fn a -> a.severity == &1 end), do: &1)
          )
      )

    ~H"""
    <div class="relative contents sm:block" id="alerts-bar">
      <button
        type="button"
        phx-click="toggle_alerts"
        aria-expanded={to_string(@open)}
        aria-controls="alerts-panel"
        class={[
          "btn btn-ghost btn-sm hidden gap-1.5 transition-colors sm:inline-flex",
          @open && "bg-base-200",
          @worst == "urgent" && "text-error",
          @worst == "warning" && "text-warning"
        ]}
        title={
          case @count do
            0 -> "No alerts"
            1 -> "1 alert"
            n -> "#{n} alerts"
          end
        }
      >
        <span class="relative flex">
          <.icon name="hero-bell" class="size-4" />
          <span
            :if={@worst == "urgent"}
            class="absolute -right-0.5 -top-0.5 size-1.5 rounded-full bg-error motion-safe:animate-pulse"
          />
        </span>
        <span class={[
          "min-w-5 rounded-full px-1.5 text-2xs font-semibold tabular-nums",
          @count == 0 && "bg-base-300 text-base-content/50",
          @count > 0 && @worst == "urgent" && "bg-error text-error-content",
          @count > 0 && @worst == "warning" && "bg-warning text-warning-content",
          @count > 0 && is_nil(@worst) && "bg-info text-info-content"
        ]}>
          {@count}
        </span>
        <.icon
          name="hero-chevron-down"
          class={["size-3 opacity-50 transition-transform", @open && "rotate-180"]}
        />
      </button>

      <div
        :if={@open}
        id="alerts-panel"
        phx-click-away={JS.push("toggle_alerts")}
        phx-window-keydown={JS.push("toggle_alerts")}
        phx-key="Escape"
        class={[
          "kanban-modal-in z-50 overflow-hidden rounded-box bg-base-100 shadow-xl ring-1 ring-base-content/10",
          "fixed inset-x-2 bottom-[calc(3.75rem+env(safe-area-inset-bottom)+0.5rem)]",
          "sm:absolute sm:inset-x-auto sm:bottom-auto sm:right-0 sm:top-full sm:mt-1.5 sm:w-[min(24rem,calc(100vw-1rem))]"
        ]}
      >
        <div class="flex items-center justify-between border-b border-base-300/70 px-3 py-2">
          <span class="text-sm font-semibold">Alerts</span>
          <button
            :if={@alerts != []}
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="dismiss_all_alerts"
          >
            Dismiss all
          </button>
        </div>
        <p :if={@alerts == []} class="px-3 py-6 text-center text-sm text-base-content/50">
          Nothing needs your attention.
        </p>
        <ul class="max-h-[60vh] divide-y divide-base-300/60 overflow-y-auto kanban-scroll">
          <li
            :for={alert <- @alerts}
            id={"alert-#{alert.id}"}
            class="group flex items-start gap-2.5 px-3 py-2.5 hover:bg-base-200/50"
          >
            <.icon
              name={Slipdock.Automations.Alert.icon(alert.severity)}
              class={[
                "mt-0.5 size-4 shrink-0",
                alert.severity == "urgent" && "text-error",
                alert.severity == "warning" && "text-warning",
                alert.severity == "info" && "text-info"
              ]}
            />
            <div class="min-w-0 flex-1">
              <p class="text-sm font-medium leading-snug">{alert.title}</p>
              <p :if={alert.body} class="mt-0.5 whitespace-pre-line text-xs text-base-content/70">
                {alert.body}
              </p>
              <div class="mt-1 flex items-center gap-2 text-2xs text-base-content/50">
                <.link
                  :if={alert.card}
                  navigate={~p"/boards/#{alert.board_id}/cards/#{alert.card_id}"}
                  class="truncate font-medium text-primary hover:underline"
                >
                  {alert.card.title}
                </.link>
                <span :if={alert.board} class="truncate">{alert.board.name}</span>
              </div>
            </div>
            <button
              type="button"
              class="btn btn-ghost btn-xs btn-square opacity-40 transition-opacity group-hover:opacity-100"
              phx-click="dismiss_alert"
              phx-value-id={alert.id}
              aria-label={"Dismiss “#{alert.title}”"}
              title="Dismiss"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} auto_dismiss />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  attr :class, :string, default: "size-7"
  attr :variant, :atom, default: :simple, values: [:simple, :detailed]
  attr :icon_class, :string, default: nil, doc: "ignored; kept so existing callers still compile"

  @doc """
  The app mark. The icon ships with its own tile and corner radius (see
  `brand/BRAND.md`), so there is no wrapper tile here to tint — the brand is
  fixed rather than themed.

  BRAND.md asks for the simplified icon below 48px and the detailed one at 48px
  and above, which is why the variant is a choice rather than one file
  everywhere: the detailed one silts up at header size and the simple one looks
  bare when it is big.
  """
  def brand_mark(assigns) do
    ~H"""
    <span class={["inline-flex shrink-0", @class]}>
      <img src={brand_icon(@variant, :light)} alt="Slipdock" class="size-full dark:hidden" />
      <img src={brand_icon(@variant, :dark)} alt="Slipdock" class="hidden size-full dark:block" />
    </span>
    """
  end

  # BRAND.md: never the navy tile on a dark surface. Against this theme's dark
  # header the ink tile measures 1.3:1 — a shape nobody can see — so dark takes
  # the reversed artwork, light tile and ink piers.
  defp brand_icon(:detailed, :dark), do: ~p"/images/brand/icon-reversed.svg"
  defp brand_icon(:detailed, _), do: ~p"/images/brand/icon.svg"
  defp brand_icon(_, :dark), do: ~p"/images/brand/icon-simple-reversed.svg"
  defp brand_icon(_, _), do: ~p"/images/brand/icon-simple.svg"

  attr :class, :string, default: "h-4"

  @doc """
  The name, as artwork rather than as text.

  The dot of the "i" is the orange card, tilted — BRAND.md is explicit that the
  wordmark is never drawn with an ordinary dot, which is exactly what setting
  "Slipdock" in the UI font produces. The two variants differ only in the
  letter colour (Harbor ink on light, Page on dark); the card stays orange in
  both, so they are swapped by theme rather than recoloured.

  The file carries its own `<title>`, so the `alt` here is what a screen reader
  announces and the name stays readable to one.
  """
  def brand_wordmark(assigns) do
    ~H"""
    <span class={["inline-flex items-center", @class]}>
      <img
        src={~p"/images/brand/wordmark.svg"}
        alt="Slipdock"
        class="h-full w-auto dark:hidden"
      />
      <img
        src={~p"/images/brand/wordmark-reversed.svg"}
        alt="Slipdock"
        class="hidden h-full w-auto dark:block"
      />
    </span>
    """
  end

  attr :theme, :string, required: true, values: ~w(system light dark)
  attr :icon, :string, required: true
  attr :label, :string, required: true

  # A theme choice inside the account menu, ticked when it is the current one.
  defp theme_item(assigns) do
    ~H"""
    <button type="button" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme={@theme}>
      <.icon name={@icon} class="size-4" /> {@label}
      <.icon name="hero-check" class={["ml-auto size-4 text-primary", theme_check(@theme)]} />
    </button>
    """
  end

  defp theme_check("system"), do: "hidden [[data-theme-source=system]_&]:inline"

  defp theme_check("light"),
    do: "hidden [[data-theme=light][data-theme-source=user]_&]:inline"

  defp theme_check("dark"),
    do: "hidden [[data-theme=dark][data-theme-source=user]_&]:inline"

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center rounded-full border-2 border-base-300 bg-base-300">
      <div class="absolute left-0 h-full w-1/3 rounded-full border-1 border-base-200 bg-base-100 brightness-200 transition-[left] [[data-theme-source=system]_&]:left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3" />

      <button
        class="flex w-1/3 cursor-pointer p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  # How many people are waiting for an admin to say yes. Only ever asked on an
  # admin's own menu, so the query costs nothing on anybody else's page — and a
  # queue with no badge is a queue discovered a month late.
  defp waiting_signups do
    if Slipdock.Settings.signup_mode() == :approval,
      do: Slipdock.Accounts.count_pending_signups(),
      else: 0
  end
end

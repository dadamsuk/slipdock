defmodule SlipdockWeb.BoardLive.BoardView do
  @moduledoc """
  The board LiveView's own markup: the board's header row (its breadcrumb) and buttons, the
  board view itself (its lists, their cards, adding to them), its toolbar,
  and the strip that says where the keyboard is. The other views have
  components of their own; the panels over them are LiveComponents.

  Everything here is drawn from assigns the LiveView passes in; the events
  it sends are the LiveView's (the buttons that open a panel target it).
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents

  alias Slipdock.Palette
  alias Slipdock.Boards.Board
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.BoardLive.BoardView.Kanban

  attr :board, :any, required: true
  attr :ancestry, :list, required: true
  attr :paths, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :can_write, :boolean, required: true

  attr :waiting_count, :integer,
    default: 0,
    doc: "what in this board's tree waits on the reader (#2095, `Slipdock.Work.Tree`)"

  @doc "The header's breadcrumb: the boards above this one, and this one."
  def board_nav(assigns) do
    ~H"""
    <nav class="flex min-w-0 items-center gap-1 text-sm">
      <%!-- On one row the mark beside this already goes to the boards. --%>
      <.link
        navigate={~p"/"}
        class="hidden shrink-0 text-base-content/50 hover:text-base-content sm:inline lg:hidden"
      >
        Boards
      </.link>
      <.icon
        name="hero-chevron-right"
        class="hidden size-3 shrink-0 text-base-content/40 sm:inline lg:hidden"
      />
      <%!-- Only the boards above: each card between them is the board after
            it under the same name, and the last is this one. --%>
      <span
        :for={%{board: b} <- @ancestry}
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
      </span>
      <%!-- The board's code and switcher key are for the CLI and the
            keyboard: they live in the name's tooltip and the ⋯ menu's Copy
            board code, not as chips beside it (#1716). --%>
      <.link
        :if={@can_manage}
        id="board-name"
        patch={@paths.settings}
        class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
        title={board_handles_title(@board, @board.description || "Board settings")}
      >
        <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
        <span class="truncate font-semibold">{@board.name}</span>
      </.link>
      <div
        :if={!@can_manage}
        id="board-name"
        class="flex min-w-0 items-center gap-2 px-2 py-1"
        title={
          board_handles_title(
            @board,
            "Shared with you (#{if @can_write, do: "can edit", else: "read only"})"
          )
        }
      >
        <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
        <span class="truncate font-semibold">{@board.name}</span>
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
      <.link
        :for={%{board: pb} <- Enum.take(@ancestry, -1)}
        navigate={~p"/boards/#{pb}"}
        class="btn btn-ghost btn-xs shrink-0 gap-1"
        title={"Open the board that holds the parent card: #{pb.name}"}
      >
        <.icon name="hero-squares-2x2" class="size-3.5" />
        <span class="hidden sm:inline">Parent board</span>
      </.link>
      <%!-- What in this tree waits on me (#2095): to My work, kept to it. --%>
      <.link
        :if={@waiting_count > 0}
        id="board-waiting"
        navigate={~p"/work?board=#{@board.id}"}
        class="chip shrink-0 bg-warning/15 text-warning hover:bg-warning/25"
        title="What on this board's tree is waiting on you, in My work"
      >
        <.icon name="hero-pause-circle" class="size-3.5" /> Waiting on you: {@waiting_count}
      </.link>
    </nav>
    """
  end

  attr :board, :any, required: true
  attr :paths, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :can_write, :boolean, required: true
  attr :card_only, :boolean, required: true
  attr :view_only, :boolean, required: true
  attr :sprint_of, :any, required: true
  attr :ai?, :boolean, required: true
  attr :rules, :list, required: true

  attr :inbound, :boolean, default: false, doc: "whether the menu offers Email to this board"

  attr :waiting_muted, :any,
    default: :none,
    doc:
      "the board whose mute keeps this one off my Waiting on you, nil if none; :none hides the menu item (#2069)"

  @doc "The board's own buttons, at the end of its toolbar: sprints, the chat and the board's menu, sharing among it."
  def board_actions(assigns) do
    ~H"""
    <%!-- A box of its own that gives way to the toolbar's row, so tests and
          the phone's rules can find the board's buttons wherever they sit. --%>
    <div id="board-actions" class="contents">
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
        :if={!@view_only and !@card_only and (Board.sprints?(@board) or @sprint_of)}
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
        <span class="hidden lg:inline">Charts</span>
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
      <%!-- Sharing in view (#1716): the settings panel on its Sharing tab,
            for whoever the ⋯ menu's Share this board is there for. A phone
            has it in the navigation Menu. --%>
      <.link
        :if={@can_manage and !@view_only and !@card_only}
        id="board-share-button"
        patch={share_path(@paths.settings)}
        class="btn btn-ghost btn-sm hidden gap-1.5 sm:inline-flex"
        title="Share this board"
      >
        <.icon name="hero-user-plus" class="size-4" /> Share
      </.link>
      <button
        :if={@ai? and !@card_only}
        type="button"
        id="board-chat"
        class="btn btn-ghost btn-sm btn-square hidden sm:inline-flex"
        title="Chat about this page with AI"
        aria-label="Chat about this page with AI"
        phx-click="toggle"
        phx-target="#page-ai"
      >
        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" />
      </button>
      <%!-- On a phone this and the chat are the floating navigation's Menu
            (board_menu/1), leaving the toolbar the room for the view's own. --%>
      <.board_more_menu
        :if={!@view_only and !@card_only}
        code={@board.code}
        paths={@paths}
        can_manage={@can_manage}
        rules={@rules}
        inbound={@inbound}
        waiting_muted={@waiting_muted}
      />
    </div>
    """
  end

  attr :paths, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :rules, :list, required: true
  attr :inbound, :boolean, default: false, doc: "whether the menu offers Email to this board"
  attr :code, :string, default: nil, doc: "the board's code, for the menu's Copy board code"

  attr :navigate, :boolean,
    default: false,
    doc: "the menu's panels by navigating, from a LiveView that isn't the board's (the wiki)"

  attr :waiting_muted, :any,
    default: :none,
    doc:
      "the board whose mute keeps this one off my Waiting on you, nil if none; :none hides the menu item (#2069)"

  @doc "The board's `…` menu on a wide screen: the board's toolbar, and the wiki's."
  def board_more_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end hidden sm:block">
      <div tabindex="0" role="button" class="btn btn-ghost btn-sm btn-square" title="More">
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </div>
      <ul
        tabindex="0"
        class="menu dropdown-content z-40 mt-2 w-52 rounded-box bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
      >
        <.board_menu_items
          share_id="board-share"
          code={@code}
          paths={@paths}
          can_manage={@can_manage}
          rules={@rules}
          inbound={@inbound}
          navigate={@navigate}
          waiting_muted={@waiting_muted}
        />
      </ul>
    </div>
    """
  end

  attr :paths, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :card_only, :boolean, required: true
  attr :view_only, :boolean, required: true
  attr :ai?, :boolean, required: true
  attr :rules, :list, required: true
  attr :inbound, :boolean, default: false, doc: "whether the menu offers Email to this board"
  attr :code, :string, default: nil, doc: "the board's code, for the menu's Copy board code"

  attr :navigate, :boolean,
    default: false,
    doc: "the menu's panels by navigating, from a LiveView that isn't the board's (the wiki)"

  attr :waiting_muted, :any,
    default: :none,
    doc:
      "the board whose mute keeps this one off my Waiting on you, nil if none; :none hides the menu item (#2069)"

  @doc """
  The board's entries in the phone's navigation Menu: what the header's
  chat button and `…` menu hold on a wider screen, which a phone hides.
  """
  def board_menu(assigns) do
    ~H"""
    <li class="menu-title">This board</li>
    <li :if={@ai? and !@card_only}>
      <button type="button" id="board-chat-menu" phx-click="toggle" phx-target="#page-ai">
        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" /> Chat about this page with AI
      </button>
    </li>
    <.board_menu_items
      :if={!@view_only and !@card_only}
      share_id="board-share-menu"
      code={@code}
      paths={@paths}
      can_manage={@can_manage}
      rules={@rules}
      inbound={@inbound}
      navigate={@navigate}
      waiting_muted={@waiting_muted}
    />
    """
  end

  attr :share_id, :string, required: true
  attr :code, :string, default: nil
  attr :paths, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :rules, :list, required: true
  attr :inbound, :boolean, default: false, doc: "whether the menu offers Email to this board"

  attr :navigate, :boolean,
    default: false,
    doc: "the menu's panels by navigating, from a LiveView that isn't the board's (the wiki)"

  attr :waiting_muted, :any,
    default: :none,
    doc:
      "the board whose mute keeps this one off my Waiting on you, nil if none; :none hides the menu item (#2069)"

  # The board's own menu, wherever it is drawn: the toolbar's `…` or the
  # phone's Menu, each with its own id on the share link. Three groups:
  # what you do with the board, how it is set up, and what it has done.
  defp board_menu_items(assigns) do
    ~H"""
    <li :if={@can_manage}>
      <.menu_link id={@share_id} to={@paths.settings} navigate={@navigate}>
        <.icon name="hero-user-plus" class="size-4" /> Share this board
      </.menu_link>
    </li>
    <%!-- The code the CLI and `[[links]]` take, copied by the CopyText
          hook from the span beside the label (#1716). --%>
    <li :if={@code}>
      <button
        type="button"
        id={@share_id <> "-copy-code"}
        phx-hook="CopyText"
        data-target={@share_id <> "-code"}
      >
        <.icon name="hero-clipboard" class="size-4" />
        <span data-label>Copy board code</span>
        <span id={@share_id <> "-code"} class="ml-auto font-mono text-2xs text-base-content/60">{@code}</span>
      </button>
    </li>
    <li>
      <.link navigate={@paths.tidy} id={@share_id <> "-tidy"}>
        <.icon name="hero-sparkles" class="size-4" /> Tidy up…
      </.link>
    </li>
    <%!-- Inbound mail on and the reader can add cards: their own addresses
          for the board (#1245, `SlipdockWeb.InboundAddressesComponent`). --%>
    <li :if={@inbound}>
      <button
        type="button"
        id={@share_id <> "-inbound"}
        phx-click="open"
        phx-target="#board-inbound"
      >
        <.icon name="hero-envelope" class="size-4" /> Email to this board
      </button>
    </li>

    <li class="mt-1 border-t border-base-300/60 pt-1">
      <.menu_link to={@paths.tags} navigate={@navigate}><.icon name="hero-tag" class="size-4" /> Tags</.menu_link>
    </li>
    <li :if={@can_manage}>
      <.menu_link to={@paths.automations} navigate={@navigate}>
        <.icon name="hero-cpu-chip" class="size-4" /> Automations
        <span :if={@rules != []} class="badge badge-ghost badge-xs">{length(@rules)}</span>
      </.menu_link>
    </li>
    <%!-- Agentic Building (#2011): a page of its own, so always navigated
          to, and only while the board's switch is on. --%>
    <li :if={@can_manage and @paths[:agentic]}>
      <.link navigate={@paths[:agentic]} id={@share_id <> "-agentic"}>
        <.icon name="hero-wrench-screwdriver" class="size-4" /> Agentic Building
      </.link>
    </li>
    <li :if={@can_manage}>
      <.menu_link to={@paths.settings} navigate={@navigate}>
        <.icon name="hero-cog-6-tooth" class="size-4" /> Board settings
      </.menu_link>
    </li>

    <li class="mt-1 border-t border-base-300/60 pt-1">
      <.menu_link to={@paths.activity} navigate={@navigate}><.icon name="hero-bolt" class="size-4" />
      Activity</.menu_link>
    </li>
    <li>
      <.menu_link to={@paths.archive} navigate={@navigate}>
        <.icon name="hero-archive-box" class="size-4" /> Archived cards
      </.menu_link>
    </li>
    <%!-- Mine alone (#2069): nothing from this board's tree on my Waiting
          on you. The board works as before, for everyone. --%>
    <li :if={@waiting_muted != :none} class="mt-1 border-t border-base-300/60 pt-1">
      <button
        :if={is_nil(@waiting_muted)}
        type="button"
        id={@share_id <> "-mute-waiting"}
        phx-click="mute_waiting"
        title="Nothing from this board on my Waiting on you. The board works as before for everyone."
      >
        <.icon name="hero-bell-slash" class="size-4" /> Mute on my Waiting on you
      </button>
      <button
        :if={@waiting_muted}
        type="button"
        id={@share_id <> "-unmute-waiting"}
        phx-click="unmute_waiting"
        phx-value-board={@waiting_muted.id}
      >
        <.icon name="hero-bell" class="size-4" /> Unmute {@waiting_muted.name} on my Waiting on you
      </button>
    </li>
    """
  end

  # The settings panel's URL, opening on its Sharing tab.
  defp share_path(settings) do
    uri = URI.parse(settings)
    query = (uri.query || "") |> URI.decode_query() |> Map.put("tab", "sharing")
    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  attr :to, :string, required: true
  attr :navigate, :boolean, required: true
  attr :rest, :global
  slot :inner_block, required: true

  # A panel of the board's: patched to where the board's LiveView is the one
  # showing, navigated to from anywhere else.
  defp menu_link(%{navigate: true} = assigns),
    do: ~H"<.link navigate={@to} {@rest}>{render_slot(@inner_block)}</.link>"

  defp menu_link(assigns),
    do: ~H"<.link patch={@to} {@rest}>{render_slot(@inner_block)}</.link>"

  attr :board, :any, required: true
  attr :columns, :list, required: true
  attr :filters, :map, required: true
  attr :filtering, :boolean, required: true
  attr :page_hit, :any, default: nil, doc: "the wiki page whose code is in the search box"
  attr :card_hit, :any, default: nil, doc: "the card elsewhere in the tree whose id is searched"
  attr :swim, Config, required: true
  attr :swim_view, :any, required: true
  attr :swim_dirty, :boolean, required: true
  attr :form_key, :integer, required: true
  attr :can_write, :boolean, required: true
  attr :can_manage, :boolean, required: true
  attr :view_only, :boolean, required: true
  attr :view_grants, :list, required: true
  attr :groups, :list, required: true
  attr :share_key, :integer, required: true
  attr :favourites, :any, required: true
  attr :narrow?, :boolean, required: true
  attr :renaming_column, :any, required: true
  attr :focus, :any, required: true
  attr :adding_to, :any, required: true
  attr :adding_column, :boolean, required: true
  attr :uploads, :map, required: true
  attr :select_mode, :boolean, default: false
  attr :card_view_names, :list, default: [], doc: "the reader's named card views (#2031)"
  attr :zone, :string, default: "Etc/UTC", doc: "the reader's timezone"
  attr :pulse, :map, default: nil, doc: "`Slipdock.Pulse.for_board/2`, when the strip is on"
  attr :pauses, :list, default: [], doc: "`State.board_pauses/1`: the tree's runner pauses"
  attr :release, :any, default: nil, doc: "`State.board_release/2`: a batched tree's releases"
  attr :waiting_muted, :any, default: nil, doc: "the board whose mute covers this one (#2069)"
  attr :waiting_filter, :boolean, default: false, doc: "`?waiting=me` (#2095)"
  attr :dora, :map, default: nil, doc: "`Slipdock.Dora.for_board/2`, when delivery metrics are on"

  attr :right_now, :map,
    default: nil,
    doc: "`Slipdock.Now.counts/1`, while the board's Agentic Building is on (#2103)"

  attr :revealed_snoozed, :any,
    default: MapSet.new(),
    doc: "the lists whose snoozed cards are shown, faded (W-1803)"

  attr :selected, :any,
    default: MapSet.new(),
    doc: "the ids of the cards picked out in select mode"

  attr :search_layout, :atom,
    default: :list,
    doc: "while filtering, `:list` (the matches grouped down the page, #2809) or `:board`"

  attr :result_folds, :any,
    default: MapSet.new(),
    doc: "the result groups whose fold was clicked (`SearchResults.folded?/3`)"

  slot :toolbar_actions, doc: "the board's own buttons, at the toolbar's end right of Views"

  @doc "The board view: its toolbar, then the lists side by side."
  def kanban(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <Kanban.board_toolbar
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
        select_mode={@select_mode}
        card_view_names={@card_view_names}
      >
        {render_slot(@toolbar_actions)}
      </Kanban.board_toolbar>
      <.pause_banner pauses={@pauses} can_manage={@can_manage} />
      <.release_banner release={@release} can_manage={@can_manage} />
      <.muted_banner waiting_muted={@waiting_muted} board_id={@board.id} />
      <.waiting_banner :if={@waiting_filter} board={@board} />
      <%!-- The board's pulse in plain words (#1113): only when the owner
            turned it on in settings (`show_pulse`). With Agentic Building on
            it opens the Right now page (#2124), what is in progress at this
            moment; otherwise the visualise view (#1650). A view-only share
            can open neither, so for them it stays plain text. --%>
      <.link
        :if={@pulse && !@view_only}
        id="board-pulse"
        navigate={pulse_path(@board, @right_now)}
        title={pulse_title(@right_now)}
        class="flex items-center gap-2 border-b border-base-300 bg-base-100/60 px-4 py-1.5 text-xs text-base-content/70 hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="hero-chart-bar" class="size-3.5 shrink-0" />
        <span>{Slipdock.Pulse.sentence(@pulse)}</span>
      </.link>
      <p
        :if={@pulse && @view_only}
        id="board-pulse"
        class="flex items-center gap-2 border-b border-base-300 bg-base-100/60 px-4 py-1.5 text-xs text-base-content/70"
      >
        <.icon name="hero-chart-bar" class="size-3.5 shrink-0" />
        <span>{Slipdock.Pulse.sentence(@pulse)}</span>
      </p>
      <%!-- Delivery performance (#1134): only while the board's delivery
            metrics are on; a nudge to wire CI until the first deploy. Once
            there are deploys the whole line opens the long-term numbers, the
            visualise view (#2124); a view-only share gets plain text. --%>
      <.link
        :if={@dora && @dora.last_deploy && !@view_only}
        id="board-dora"
        navigate={~p"/boards/#{@board}/visualise"}
        title="Delivery over time: open the visualise view"
        class="flex items-center gap-2 border-b border-base-300 bg-base-100/60 px-4 py-1.5 text-xs text-base-content/70 hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="hero-rocket-launch" class="size-3.5 shrink-0" />
        <.dora_parts dora={@dora} />
      </.link>
      <p
        :if={@dora && !(@dora.last_deploy && !@view_only)}
        id="board-dora"
        class="flex items-center gap-2 border-b border-base-300 bg-base-100/60 px-4 py-1.5 text-xs text-base-content/70"
      >
        <.icon name="hero-rocket-launch" class="size-3.5 shrink-0" />
        <.dora_parts :if={@dora.last_deploy} dora={@dora} />
        <span :if={!@dora.last_deploy}>
          Delivery metrics are on: no deploys recorded yet. Wrap your deploy step in CI with
          <code>slipdock deploy run</code>
          (board settings → Delivery metrics shows how).
        </span>
      </p>
      <%!-- What the runners are doing (#2103): on a board with Agentic
            Building on, one click to the Right now page. The pulse line
            above opens that page when it shows (#2124), so this one stands
            in for it only when the pulse is off. --%>
      <.link
        :if={@right_now && !@pulse && !@view_only}
        id="board-now"
        navigate={~p"/boards/#{@board}/now"}
        title="Which runners are doing what, and the cards in progress"
        class="flex items-center gap-2 border-b border-base-300 bg-base-100/60 px-4 py-1.5 text-xs text-base-content/70 hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="hero-cpu-chip" class="size-3.5 shrink-0" />
        <span>{Slipdock.Now.sentence(%{counts: @right_now}) || "Nothing running right now"}</span>
        <span class="ml-auto shrink-0">Right now ›</span>
      </.link>
      <Kanban.search_banner
        board={@board}
        columns={@columns}
        filters={@filters}
        filtering={@filtering}
        page_hit={@page_hit}
        card_hit={@card_hit}
        search_layout={@search_layout}
      />

      <Kanban.search_list
        board={@board}
        columns={@columns}
        filtering={@filtering}
        search_layout={@search_layout}
        result_folds={@result_folds}
        narrow?={@narrow?}
        select_mode={@select_mode}
        selected={@selected}
        swim={@swim}
        focus={@focus}
        can_write={@can_write}
        favourites={@favourites}
        zone={@zone}
      />

      <Kanban.list_pager
        :if={@narrow? and @columns != [] and not (@filtering and @search_layout == :list)}
        columns={@columns}
      />

      <Kanban.lists
        board={@board}
        columns={@columns}
        filtering={@filtering}
        search_layout={@search_layout}
        swim={@swim}
        form_key={@form_key}
        can_write={@can_write}
        favourites={@favourites}
        narrow?={@narrow?}
        renaming_column={@renaming_column}
        focus={@focus}
        adding_to={@adding_to}
        adding_column={@adding_column}
        uploads={@uploads}
        select_mode={@select_mode}
        zone={@zone}
        revealed_snoozed={@revealed_snoozed}
        selected={@selected}
      />
    </div>
    """
  end

  attr :pauses, :list, required: true
  attr :can_manage, :boolean, required: true

  @doc """
  The brake, on every board of the paused tree (#1116): who paused what on
  which board, and why, with Resume for the owner. Each Resume lets off
  exactly its own pause.
  """
  def pause_banner(assigns) do
    ~H"""
    <div
      :for={%{pause: p, root: root} <- @pauses}
      id={"pause-banner-#{p.id}"}
      role="status"
      class="flex flex-wrap items-center gap-2 border-b border-warning/40 bg-warning/15 px-4 py-1.5 text-sm"
    >
      <.icon name="hero-pause-circle" class="size-4 shrink-0 text-warning" />
      <span class="min-w-0 flex-1">
        Paused on {root.name}<span :if={p.pool}> · pool {p.pool}</span>
        by {Slipdock.Runners.Pause.who(p)}: {p.reason}
        <span class="text-xs text-base-content/60">
          · no runner job is taken and no list sends a card until it is resumed
        </span>
      </span>
      <button
        :if={@can_manage}
        type="button"
        id={"resume-pause-#{p.id}"}
        class="btn btn-xs"
        phx-click="resume_pause"
        phx-value-pool={p.pool}
      >
        Resume
      </button>
    </div>
    """
  end

  attr :release, :any, default: nil, doc: "`Slipdock.Releases.status/1`, on a batched tree"
  attr :can_manage, :boolean, required: true

  @doc """
  A batched tree's releases (#2835), on every board of it: a hold after a
  red release (#2838), the release running (with a link to its build once
  its job has fired it, #3005), the follow-up queued and how many merged
  cards await one, with Release now (and Lift hold, while held) for the
  owner. Nothing while there is nothing to say.
  """
  def release_banner(assigns) do
    assigns =
      assign(assigns,
        line: assigns.release && Slipdock.Releases.line(assigns.release, awaiting: false),
        awaiting: assigns.release && Slipdock.Releases.awaiting_text(assigns.release)
      )

    ~H"""
    <div
      :if={@line || @awaiting}
      id="release-banner"
      role="status"
      class="flex flex-wrap items-center gap-2 border-b border-info/40 bg-info/10 px-4 py-1.5 text-sm"
    >
      <.icon name="hero-rocket-launch" class="size-4 shrink-0 text-info" />
      <div id="release-banner-line" class="min-w-0 flex-1">
        <.release_line release={@release} id="release" />
      </div>
      <button
        :if={@can_manage}
        type="button"
        id="release-now"
        class="btn btn-xs"
        phx-click="release_now"
        data-confirm="Release this board's merged work now?"
      >
        Release now
      </button>
      <button
        :if={@can_manage and @release.hold}
        type="button"
        id="release-lift-hold"
        class="btn btn-xs btn-warning"
        phx-click="lift_release_hold"
        data-confirm="Lift the hold? Releases run again; nothing is released now."
      >
        Lift hold
      </button>
    </div>
    """
  end

  attr :release, :any, required: true, doc: "`Slipdock.Releases.status/1`"
  attr :id, :string, required: true, doc: "the prefix of its links' ids"
  attr :empty, :string, default: nil, doc: "what to say when there is nothing to say"

  @doc """
  Where a tree's releases stand, in one line, for the board's banner and
  the Agentic Building page (#2995): the hold and why, with its failing
  run in brackets beside the reason (the link is the hold's, not the
  awaiting cards'), then the fix card, the release running with its
  build beside it (#3091: before the follow-up queued, not after it),
  the follow-up queued, and the cards awaiting (`release_awaiting/1`).
  """
  def release_line(assigns) do
    release = assigns.release
    hold = Slipdock.Releases.hold_text(release)
    awaiting = Slipdock.Releases.awaiting_text(release)

    # `Releases.line/2` on the status narrowed to one part at a time, so
    # the running release's build link sits beside it, before the
    # follow-up queued (#3091).
    part = fn only ->
      Slipdock.Releases.line(Map.merge(release, only), awaiting: false, hold: false)
    end

    texts = [
      hold: hold,
      fix: part.(%{running: nil, queued: nil}),
      running: part.(%{hold: nil, queued: nil}),
      queued: part.(%{hold: nil, running: nil}),
      awaiting: awaiting
    ]

    parts = for {name, text} <- texts, text, do: name

    assigns =
      assign(assigns,
        parts: parts,
        texts: texts,
        hold_run: hold && release.hold["run_url"],
        running_run: release.running && release.running.run_url,
        empty: if(parts == [], do: assigns.empty)
      )

    ~H"""
    {@empty}
    <span :for={{part, i} <- Enum.with_index(@parts)} id={"#{@id}-part-#{part}"}>
      {if i > 0, do: " · "}
      <%= case part do %>
        <% :hold -> %>
          {@texts[:hold]}
          <span :if={@hold_run} id={"#{@id}-hold-run-note"} phx-no-format>(<.link
              id={"#{@id}-hold-run"}
              href={@hold_run}
              target="_blank"
              rel="noopener noreferrer"
              class="link"
            >the failing run</.link>)</span>
        <% :fix -> %>
          {@texts[:fix]}
        <% :running -> %>
          {@texts[:running]}
          <.link
            :if={@running_run}
            id={"#{@id}-running-run"}
            href={@running_run}
            target="_blank"
            rel="noopener noreferrer"
            class="link"
          >
            follow the build
          </.link>
        <% :queued -> %>
          {@texts[:queued]}
        <% :awaiting -> %>
          <.release_awaiting release={@release} id={"#{@id}-awaiting"} />
      <% end %>
    </span>
    """
  end

  attr :release, :any, required: true, doc: "`Slipdock.Releases.status/1`"
  attr :id, :string, required: true

  @doc """
  The merged cards awaiting release (#3038): their count, which opens
  the list of them, each a link to its card, so a person sees what the
  next release takes. Nothing while none await or a release is running.
  """
  def release_awaiting(assigns) do
    assigns = assign(assigns, text: Slipdock.Releases.awaiting_text(assigns.release))

    ~H"""
    <details :if={@text} id={@id} class="inline-block align-top">
      <summary id={"#{@id}-toggle"} class="link cursor-pointer" title="Show the cards">
        {@text}
      </summary>
      <ul id={"#{@id}-cards"} class="mt-1 mb-1 list-disc pl-5">
        <li :for={card <- @release.awaiting} id={"#{@id}-card-#{card.id}"}>
          <.link navigate={~p"/boards/#{card.board_id}/cards/#{card.id}"} class="link">
            #{card.id} {card.title}
          </.link>
        </li>
      </ul>
    </details>
    """
  end

  attr :waiting_muted, :any, default: nil, doc: "the board whose mute covers this one (#2069)"
  attr :board_id, :integer, required: true

  @doc """
  This board is muted on my Waiting on you (#2069), so I know why it is
  quiet there: by itself or by a board above it, with Unmute. Only I see it.
  """
  def muted_banner(assigns) do
    ~H"""
    <.callout
      :if={is_map(@waiting_muted)}
      id="waiting-muted-banner"
      kind={:info}
      class="rounded-none border-l-2 py-1.5 text-xs"
    >
      Muted on your Waiting on you<span :if={@waiting_muted.id != @board_id}> by {@waiting_muted.name}</span>:
      nothing from here shows there for you. The board works as before, for everyone.
      <button
        type="button"
        id="waiting-muted-unmute"
        class="btn btn-ghost btn-xs ml-1"
        phx-click="unmute_waiting"
        phx-value-board={@waiting_muted.id}
      >
        Unmute
      </button>
    </.callout>
    """
  end

  attr :board, :any, required: true

  @doc """
  The lists keep only what waits on me (#2095, `?waiting=me`), as an epic's
  chip opens its sub-board: says so, with the way back to everything.
  """
  def waiting_banner(assigns) do
    ~H"""
    <.callout id="waiting-filter-banner" kind={:info} class="rounded-none border-l-2 py-1.5 text-xs">
      Showing only the cards waiting on you, and the cards holding them.
      <.link id="waiting-filter-clear" patch={~p"/boards/#{@board}"} class="link ml-1">
        Show all
      </.link>
    </.callout>
    """
  end

  attr :focus, :map, required: true
  attr :focus_title, :string, default: nil

  @doc "Where the keyboard is on the board, and what the keys do from there."
  def focus_toast(assigns) do
    ~H"""
    <div class="kanban-toast-in pointer-events-none fixed bottom-4 left-1/2 z-50 flex max-w-[calc(100vw-2rem)] -translate-x-1/2 items-center gap-2 rounded-full bg-base-content px-4 py-2 text-xs text-base-100 shadow-xl">
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
    """
  end

  attr :selected, :any, required: true
  attr :tags, :list, required: true
  attr :destinations, :list, required: true, doc: "`Slipdock.BulkEdit.destinations/2`"

  @doc """
  Select mode's action bar (#592): how many cards are picked out, and what
  can be done to all of them at once. Every choice is a `bulk_apply` with an
  action `Slipdock.BulkEdit.parse_action/1` reads; the two menus apply as
  soon as something is chosen in them.
  """
  def bulk_bar(assigns) do
    assigns = assign(assigns, count: MapSet.size(assigns.selected))

    ~H"""
    <div
      id="bulk-bar"
      class="kanban-toast-in fixed bottom-4 left-1/2 z-50 flex max-w-[calc(100vw-2rem)] -translate-x-1/2 flex-wrap items-center gap-2 rounded-2xl bg-base-100 px-3 py-2 text-sm shadow-xl ring-1 ring-base-content/10"
    >
      <span id="bulk-count" class="font-semibold">
        {if @count == 0,
          do: "Click cards to select them · Shift-click for a run",
          else: "#{@count} selected"}
      </span>
      <%= if @count > 0 do %>
        <span class="h-5 w-px bg-base-300"></span>
        <button
          :for={{action, label, icon} <- bulk_buttons()}
          type="button"
          id={"bulk-#{action}"}
          class="btn btn-ghost btn-xs gap-1"
          phx-click="bulk_apply"
          phx-value-action={action}
          data-confirm={
            action == "delete" &&
              "Delete #{@count} #{if @count == 1, do: "card", else: "cards"}? This can't be undone."
          }
        >
          <.icon name={icon} class="size-3.5" /> {label}
        </button>
        <form id="bulk-set" phx-change="bulk_apply" class="contents">
          <select name="action" class="select field w-36" aria-label="Set on the selected cards">
            <option value="">Set…</option>
            <optgroup :if={@tags != []} label="Add tag">
              <option :for={t <- @tags} value={"tag:#{t.id}"}>{t.name}</option>
            </optgroup>
            <optgroup :if={@tags != []} label="Remove tag">
              <option :for={t <- @tags} value={"untag:#{t.id}"}>{t.name}</option>
            </optgroup>
            <optgroup label="Priority">
              <option :for={p <- Slipdock.Boards.Card.priorities()} value={"priority:#{p}"}>
                {p}
              </option>
            </optgroup>
            <optgroup label="Add flag">
              <option :for={f <- Slipdock.Boards.Card.flags()} value={"flag:#{f}"}>{f}</option>
            </optgroup>
            <optgroup label="Remove flag">
              <option :for={f <- Slipdock.Boards.Card.flags()} value={"unflag:#{f}"}>{f}</option>
            </optgroup>
          </select>
        </form>
        <form id="bulk-move" phx-change="bulk_apply" class="contents">
          <select name="action" class="select field w-40" aria-label="Move the selected cards">
            <option value="">Move to…</option>
            <optgroup :for={{board, columns} <- @destinations} label={board.name}>
              <option :for={c <- columns} value={"move:#{c.id}"}>{c.name}</option>
            </optgroup>
          </select>
        </form>
        <button
          type="button"
          id="bulk-snooze"
          class="btn btn-ghost btn-xs gap-1"
          phx-click="open_snooze"
        >
          <span aria-hidden="true">💤</span> Snooze…
        </button>
        <button type="button" id="bulk-clear" class="btn btn-ghost btn-xs" phx-click="clear_selection">
          Clear
        </button>
      <% end %>
      <button
        type="button"
        id="bulk-done"
        class="btn btn-primary btn-xs"
        phx-click="toggle_select_mode"
      >
        Done
      </button>
    </div>
    """
  end

  defp bulk_buttons do
    [
      {"complete", "Complete", "hero-check"},
      {"reopen", "Reopen", "hero-arrow-uturn-left"},
      {"assign_me", "Assign me", "hero-user-plus"},
      {"unassign", "Unassign", "hero-user-minus"},
      {"archive", "Archive", "hero-archive-box"},
      {"delete", "Delete", "hero-trash"}
    ]
  end

  attr :dora, :map, required: true

  @doc """
  The delivery strip's metrics (#1184), each with its DORA band as a coloured
  pill: green for elite, blue for high, amber for medium, red for low. The band
  stays in the pill's words, so the colour is never the only signal.
  """
  def dora_parts(assigns) do
    {lead, parts} = Slipdock.Dora.parts(assigns.dora)
    assigns = assign(assigns, lead: lead, parts: parts)

    ~H"""
    <span class="flex flex-wrap items-center gap-x-1.5 gap-y-1">
      <span class="font-medium text-base-content/80">{String.trim_trailing(@lead)}</span>
      <%= for {part, i} <- Enum.with_index(@parts) do %>
        <span :if={i > 0} class="text-base-content/30" aria-hidden="true">·</span>
        <span class="inline-flex items-center gap-1" data-band={part.band}>
          <span>{part.text}</span>
          <span
            :if={part.band}
            class={["badge badge-xs badge-soft font-medium", dora_band_class(part.band)]}
            title={"DORA band: #{part.band}"}
          >
            {part.band}
          </span>
        </span>
      <% end %>
    </span>
    """
  end

  # Where the pulse line leads (#2124): Right now while Agentic Building is
  # on (`right_now` is set only then), else the visualise view.
  defp pulse_path(board, nil), do: ~p"/boards/#{board}/visualise"
  defp pulse_path(board, _right_now), do: ~p"/boards/#{board}/now"

  defp pulse_title(nil), do: "Open the visualise view"
  defp pulse_title(_right_now), do: "Which runners are doing what, and the cards in progress"

  @doc "The pill classes of a DORA band (#1184), shared with the Visualise page."
  def dora_band_class("elite"), do: "badge-success"
  def dora_band_class("high"), do: "badge-info"
  # The theme's amber is pale: on the light theme its soft pill all but
  # vanishes, so medium takes the darker amber for its words there.
  def dora_band_class("medium"),
    do: "badge-warning bg-warning/30 text-warning-content dark:bg-warning/10 dark:text-warning"

  def dora_band_class(_low), do: "badge-error"
end

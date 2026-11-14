defmodule SlipdockWeb.SlipdockComponents.CardFace do
  @moduledoc "The front of a card on a board: the tile itself, the marks only it draws, a placed wiki page's parts and the stand-in for a card that moved."
  use Phoenix.Component
  use SlipdockWeb, :verified_routes

  alias Phoenix.LiveView.JS
  alias Slipdock.Palette
  alias Slipdock.Swimlanes.Config
  alias Slipdock.TimeTracking
  alias SlipdockWeb.Dates

  import SlipdockWeb.CoreComponents, only: [icon: 1]
  import SlipdockWeb.SlipdockComponents.Marks
  import SlipdockWeb.SlipdockComponents.Progress
  import SlipdockWeb.SlipdockComponents.Schedule

  defp loaded_attachments(%{attachments: list}) when is_list(list), do: list
  defp loaded_attachments(_), do: []

  # The marks a card's front always drew until card views (#2031), and
  # still does by default (`Config.marks_on/0`): each shown when its element
  # is on and there is something to mark.
  defp card_marks(on, card, note_mode) do
    handoff = Slipdock.Boards.Card.open_handoff(card)
    state = Map.get(card, :state)

    %{
      # Where it was left (W-1804), while the card is open.
      handoff: on.("handoff") and not is_nil(handoff),
      handoff_note: not is_nil(handoff) and note_shown?(note_mode),
      # Waiting on a person (#1114), with what it needs.
      wait: on.("wait") and not is_nil(Slipdock.Boards.Card.open_wait(card)),
      # What kind of change it is (#1951), when it has one.
      profile: on.("profile") and not is_nil(Map.get(card, :profile)),
      # A recurring card (W-1802).
      recurrence: on.("recurrence") and not is_nil(Slipdock.Boards.Card.recurrence(card)),
      # Snoozed (W-1803): only seen where snoozed cards are shown, with the
      # day it wakes.
      snoozed: on.("snoozed") and Slipdock.Boards.Card.snoozed?(card),
      # What is happening to it and who drives it (#1117), when there is
      # something to say.
      state_line:
        on.("state_line") and match?(%Slipdock.CardState{line: line} when is_binary(line), state),
      driver: on.("driver") and match?(%Slipdock.CardState{driver: d} when is_binary(d), state)
    }
  end

  # The heart (#2031): an element like the marks.
  defp favourite_shown?(on, marks, card), do: on.("favourite") and favourite_mark?(marks, card)

  defp note_shown?(mode) when mode in ~w(short full), do: true
  defp note_shown?(_mode), do: false

  # How much of a handoff note the front shows (#2031): the card view's
  # elements when it states them, else what the caller asked.
  defp handoff_note_mode(show, asked) do
    cond do
      MapSet.member?(show, "handoff_full") -> "full"
      MapSet.member?(show, "handoff_note") -> "short"
      true -> asked
    end
  end

  @doc "The facets to show as a MapSet; `nil` means every facet."
  def show_set(nil), do: MapSet.new(Config.facet_keys() ++ Config.marks_on())
  def show_set(%MapSet{} = set), do: set
  def show_set(list) when is_list(list), do: MapSet.new(list)

  attr :card, :map, required: true

  @doc """
  The edges of a card's front in their own colours (#1209): a strip on each
  side that has one, clipped to the card's rounded corners and drawn over
  it, so the card keeps its size whichever edges are coloured.
  """
  def card_borders(assigns) do
    ~H"""
    <div
      class="pointer-events-none absolute inset-0 z-[1] overflow-hidden rounded-xl"
      data-role="card-borders"
      aria-hidden="true"
    >
      <span
        :if={@card.border_top}
        data-edge="top"
        class={["absolute inset-x-0 top-0 h-1", Palette.dot(@card.border_top)]}
      ></span>
      <span
        :if={@card.border_right}
        data-edge="right"
        class={["absolute inset-y-0 right-0 w-1", Palette.dot(@card.border_right)]}
      ></span>
      <span
        :if={@card.border_bottom}
        data-edge="bottom"
        class={["absolute inset-x-0 bottom-0 h-1", Palette.dot(@card.border_bottom)]}
      ></span>
      <span
        :if={@card.border_left}
        data-edge="left"
        class={["absolute inset-y-0 left-0 w-1", Palette.dot(@card.border_left)]}
      ></span>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :id, :string, default: nil, doc: "DOM id; defaults to card-<id>"
  attr :compact, :boolean, default: false, doc: "single-line variant for dense grids"

  attr :show, :any,
    default: nil,
    doc: "the facets to render (a list or MapSet of keys from Config.facets/1); nil shows all"

  attr :cover, :any,
    default: :auto,
    doc: "the palette colour of the cover strip; :auto uses the card's own colour"

  attr :focus, :atom,
    default: nil,
    doc: """
    where the keyboard is: `:cursor` when it points at this card (the "c"
    shortcut), `:held` when the card is being carried (the "J" shortcut)
    """

  attr :dismiss, :boolean,
    default: false,
    doc: "on a stand-in, offer to dismiss it (the reader can change the board)"

  attr :selected, :boolean,
    default: nil,
    doc: """
    in the board's select mode, whether this card is picked out (`true`) or
    not (`false`); nil outside select mode
    """

  attr :zone, :string, default: "Etc/UTC", doc: "the reader's timezone, for a snoozed card's day"

  attr :handoff_note, :string,
    default: "hide",
    doc: """
    whether an open card's front shows its handoff note (#1171): "hide" (the
    ↩ mark alone), "short" (two lines) or "full"; comfortable cards only
    """

  attr :handoff_label, :string,
    default: "Left off",
    doc: "what the board calls a handoff (#1212, `Board.handoff_label/1`)"

  attr :marks, :any,
    default: nil,
    doc: """
    the reader's favourites (`Slipdock.Favourites.marks/1`); a card in them
    shows a heart on its front
    """

  slot :actions,
    doc: """
    controls rendered at the end of the card's title row — the board view's
    "move to another list" menu. Anything in here needs a `phx-click` of its
    own, or the click finds the card's and opens it instead.
    """

  def card(%{card: %{stand_in_for_id: id}} = assigns) when not is_nil(id),
    do: stand_in_card(assigns)

  def card(assigns) do
    card = assigns.card
    page? = page?(card)
    show = show_set(assigns.show)
    on = &MapSet.member?(show, &1)
    cover = if assigns.cover == :auto, do: card.color, else: assigns.cover
    image = if on.("images"), do: Slipdock.Boards.Attachment.front_image(loaded_attachments(card))
    note_mode = handoff_note_mode(show, assigns.handoff_note)
    waiting = waiting_entry(card)
    glance = Slipdock.Work.Tree.glance(waiting)

    facets =
      on
      |> look_facets(card, cover, image)
      |> Map.merge(plan_facets(on, card))
      |> Map.merge(content_facets(on, card))
      |> Map.merge(card_marks(on, card, note_mode))
      |> waiting_marks(waiting, glance)
      |> with_range()

    assigns =
      assign(assigns,
        done: Enum.count(card.checklist_items, & &1.done),
        total: length(card.checklist_items),
        f: facets,
        meta?: meta?(facets),
        cover_color: cover,
        image: image,
        page?: page?,
        favourite?: favourite_shown?(on, assigns.marks, card),
        handoff_note: note_mode,
        handoff: Slipdock.Boards.Card.open_handoff(card),
        wait: Slipdock.Boards.Card.open_wait(card),
        waiting: waiting,
        glance: glance,
        recurrence: Slipdock.Boards.Card.recurrence(card),
        snoozed: Slipdock.Boards.Card.snoozed?(card),
        state: Map.get(card, :state),
        # A wiki page is `page-7` where a card is `12`, so the drag-and-drop
        # and the click handlers can tell the two apart.
        item_id: item_id(card),
        dom_id: assigns.id || if(page?, do: "page-#{card.id}", else: "card-#{card.id}"),
        page_path: page? && page_path(card)
      )

    ~H"""
    <div
      id={@dom_id}
      data-id={@item_id}
      class={[
        "kanban-card group relative cursor-grab rounded-xl bg-base-100 shadow-sm ring-1 ring-base-content/5",
        "outline-none transition hover:shadow-md hover:ring-primary/40 active:cursor-grabbing",
        "focus-visible:ring-2 focus-visible:ring-primary/50",
        @page? && "kanban-page",
        (@card.completed or @snoozed) && "opacity-60",
        @focus == :cursor && "z-10 ring-2 ring-secondary",
        @focus == :held && "z-10 scale-[1.02] shadow-lg ring-2 ring-primary",
        @selected && "z-10 bg-primary/5 ring-2 ring-primary"
      ]}
      data-focus={@focus}
      data-selected={@selected}
      tabindex="0"
      role="button"
      aria-pressed={if is_boolean(@selected), do: to_string(@selected)}
      phx-click={open_item(@page?, @card.id)}
      phx-keydown={open_item(@page?, @card.id)}
      phx-key="Enter"
    >
      <span
        :if={@selected}
        class="absolute -top-1.5 -right-1.5 z-10 flex size-5 items-center justify-center rounded-full bg-primary text-primary-content shadow"
        aria-hidden="true"
      >
        <.icon name="hero-check" class="size-3.5" />
      </span>
      <.card_borders :if={@f.borders} card={@card} />
      <div
        :if={@f.cover && !@compact}
        class={["h-1.5 rounded-t-xl bg-gradient-to-r", Palette.gradient(@cover_color)]}
      >
      </div>
      <img
        :if={@f.image && !@compact}
        src={Slipdock.Boards.Attachments.attachment_url(@image)}
        alt={@image.filename}
        loading="lazy"
        draggable="false"
        data-role="card-image"
        class={[
          "max-h-40 w-full bg-base-200 object-cover",
          !@f.cover && "rounded-t-xl"
        ]}
      />
      <.compact_row
        :if={@compact}
        card={@card}
        f={@f}
        page?={@page?}
        page_path={@page_path}
        cover_color={@cover_color}
        image={@image}
        favourite?={@favourite?}
        waiting={@waiting}
        dom_id={@dom_id}
        handoff={@handoff}
        handoff_label={@handoff_label}
        wait={@wait}
        recurrence={@recurrence}
        zone={@zone}
        state={@state}
        actions={@actions}
      />
      <div :if={!@compact} class="space-y-2 p-3">
        <%!-- The card's number sits in the top-right corner (#1856): at the
             end of the tags when they are shown, else of the title row. --%>
        <div :if={@f.tags} class="flex items-start gap-2">
          <div class="flex min-w-0 flex-1 flex-wrap gap-1">
            <.tag_chip :for={tag <- @card.tags} tag={tag} size="xs" />
          </div>
          <.card_id :if={@f.id and not @page?} card={@card} />
        </div>

        <%!-- The title starts where the tags and the meta row do (#1707): the
             complete toggle sits after it, so hiding it never indents the
             title, and showing it on a phone never shifts it. --%>
        <div class="flex items-start gap-2">
          <.doc_link :if={@page?} path={@page_path} class="mt-0.5 size-4" />
          <p
            data-role="card-title"
            class={[
              "min-w-0 flex-1 text-sm font-medium leading-snug",
              @card.completed && "text-base-content/70"
            ]}
          >
            {@card.title}
          </p>
          <.card_id :if={@f.id and not @page? and not @f.tags} card={@card} />
          <.favourite_mark :if={@favourite?} class="mt-1 size-3.5" />
          <.complete_toggle
            :if={@f.status and not @page?}
            card={@card}
            class="mt-0.5"
            reveal
          />
          <span :if={@actions != []} class="-mr-1 -mt-0.5 shrink-0">{render_slot(@actions)}</span>
        </div>

        <%!-- `card-meta` (#1708): neutral chips in here are plain icon and
             text (app.css drops their outline); only the tinted ones, the
             states that need attention, keep a box. --%>
        <div
          :if={@meta?}
          class="card-meta flex flex-wrap items-center gap-x-2 gap-y-1 text-base-content/60"
          data-role="card-meta"
        >
          <.flag_icon
            :for={flag <- @card.flags}
            :if={@f.flags}
            flag={flag}
            card={@card}
            class="size-3.5"
          />
          <.dependency_badge :if={@f.dependencies} card={@card} />
          <.subcards_badge :if={@f.subcards} card={@card} open={not @page?} />
          <.waiting_chip
            :if={@f.waiting_chip}
            card={@card}
            items={@waiting.mine}
            id={"#{@dom_id}-waiting"}
          />
          <.stated_pill
            :if={@f.stated}
            health={Slipdock.Boards.Card.stated_health(@card)}
            with_label={false}
          />
          <SlipdockWeb.LoopComponents.loop_chip
            :if={@f.loop}
            id={"#{@dom_id}-loop"}
            loop={Slipdock.CardState.loop(@card)}
            href={SlipdockWeb.LoopComponents.job_href(@card, Slipdock.CardState.loop(@card))}
          />
          <.assignee_chips :if={@f.assignee} users={Slipdock.Boards.Card.assignees(@card)} size="xs" />
          <.priority_badge :if={@f.priority} priority={@card.priority} />
          <.date_range_badge :if={@f.range} card={@card} />
          <.start_badge :if={@f.start_date and not @f.range} card={@card} />
          <.schedule_badges :if={@f.due_date} card={@card} due={not @f.range} />
          <.percent_badge :if={@f.percent} percent={@card.percent_complete} />
          <.profile_chip
            :if={@f.profile}
            profile={@card.profile}
            source={Map.get(@card, :profile_source)}
          />
          <.time_badge :if={@f.time} card={@card} />
          <span
            :if={@f.checklist}
            class={[
              "chip",
              if(@done == @total,
                do: "bg-success/15 text-success",
                else: "chip-line text-base-content/70"
              )
            ]}
            title="Checklist"
          >
            <.icon name="hero-clipboard-document-check" class="size-3" /> {@done}/{@total}
          </span>
          <span
            :if={@f.description}
            class="chip chip-icon chip-line text-base-content/70"
            title="Has description"
          >
            <.icon name="hero-bars-3-bottom-left" class="size-3.5" />
          </span>
          <.handoff_mark :if={@f.handoff} handoff={@handoff} label={@handoff_label} />
          <.wait_mark :if={@f.wait} wait={@wait} />
          <.recurrence_mark :if={@f.recurrence} recurrence={@recurrence} />
          <.snooze_mark :if={@f.snoozed} card={@card} zone={@zone} />
          <.driver_mark :if={@f.driver} state={@state} />
          <.age_chip :if={@f.age} state={@state} />
          <span :if={@f.comments} class="chip chip-line text-base-content/70" title="Comments">
            <.icon name="hero-chat-bubble-left" class="size-3.5" /> {length(@card.comments)}
          </span>
          <span
            :if={@f.attachments}
            class="chip chip-line text-base-content/70"
            title="Attachments"
          >
            <.icon name="hero-paper-clip" class="size-3.5" /> {length(loaded_attachments(@card))}
          </span>
        </div>
        <p
          :if={@f.waiting_line}
          id={"#{@dom_id}-waiting-line"}
          data-role="waiting-line"
          class={[
            "text-2xs leading-snug",
            if(@waiting.mine != [], do: "text-warning", else: "text-base-content/60")
          ]}
        >
          {@glance}
        </p>
        <.handoff_note
          :if={@f.handoff_note}
          handoff={@handoff}
          label={@handoff_label}
          mode={@handoff_note}
        />
        <.state_line :if={@f.state_line} state={@state} />
      </div>
    </div>
    """
  end

  # What of the card's look its front draws: each facet shown when its
  # element is on and the card has something for it.
  defp look_facets(on, card, cover, image) do
    %{
      cover: on.("cover") and not is_nil(cover),
      # Its own colour on each edge, shown with the cover colour. A card
      # element of its own since card views.
      borders: on.("borders") and Enum.any?(Slipdock.Boards.Card.borders(), &Map.get(card, &1)),
      image: not is_nil(image),
      stated: on.("status") and not is_nil(Slipdock.Boards.Card.stated_health(card)),
      status: on.("status"),
      tags: on.("tags") and card.tags != [],
      flags: on.("flags") and card.flags != [],
      # Medium is the unremarkable middle, so a card's front leaves it out:
      # high, critical and low are the ones worth a glance.
      priority: on.("priority") and priority_on_face?(card.priority)
    }
  end

  # Who has the card, when it runs and how far along it is.
  defp plan_facets(on, card) do
    %{
      assignee: on.("assignee") and Slipdock.Boards.Card.assignees(card) != [],
      # The runner loop holding it, beside the people: only while its job
      # is claimed or running, and with the assignee field.
      loop: loop_on_face?(on, card),
      start_date: on.("start_date") and not is_nil(Slipdock.Boards.Card.effective_start(card)),
      due_date: on.("due_date") and not is_nil(Slipdock.Boards.Card.effective_due(card)),
      percent: on.("percent_complete") and not is_nil(card.percent_complete),
      time: on.("time") and TimeTracking.tracked?(card),
      dependencies: on.("dependencies") and blocks_or_blocked?(card),
      subcards: on.("subcards") and not is_nil(card.sub_board)
    }
  end

  defp blocks_or_blocked?(card), do: card.blocks != [] or card.blocked_by != []

  # What is in the card, how long it has sat in its list, and its number.
  defp content_facets(on, card) do
    %{
      checklist: on.("checklist") and card.checklist_items != [],
      description: on.("description") and (card.description || "") != "",
      comments: on.("comments") and card.comments != [],
      attachments: on.("attachments") and loaded_attachments(card) != [],
      age:
        on.("age") and
          match?(%Slipdock.CardState{age: age} when is_integer(age), Map.get(card, :state)),
      # The card's number; a wiki page on the board has none, which the
      # template checks.
      id: on.("id")
    }
  end

  # Start and due, both shown and both set, draw as one range.
  defp with_range(facets), do: Map.put(facets, :range, facets.start_date and facets.due_date)

  # Whether the front has a meta row: any facet drawn in it is shown.
  defp meta?(facets) do
    facets
    |> Map.drop([:cover, :borders, :image, :status, :tags, :id, :handoff_note, :waiting_line])
    |> Map.values()
    |> Enum.any?()
  end

  attr :card, :map, required: true
  attr :f, :map, required: true
  attr :page?, :boolean, required: true
  attr :page_path, :any, required: true
  attr :cover_color, :any, required: true
  attr :image, :any, required: true
  attr :favourite?, :boolean, required: true
  attr :waiting, :map, required: true
  attr :dom_id, :string, required: true
  attr :handoff, :any, required: true
  attr :handoff_label, :string, required: true
  attr :wait, :any, required: true
  attr :recurrence, :any, required: true
  attr :zone, :string, required: true
  attr :state, :any, required: true
  attr :actions, :list, required: true

  # The single-line front, for dense grids: everything the card shows, in
  # one row.
  defp compact_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-2.5 py-1.5">
      <span :if={@f.cover} class={["size-2 shrink-0 rounded-full", Palette.dot(@cover_color)]}></span>
      <img
        :if={@f.image}
        src={Slipdock.Boards.Attachments.attachment_url(@image)}
        alt={@image.filename}
        loading="lazy"
        draggable="false"
        data-role="card-image"
        class="size-5 shrink-0 rounded object-cover"
      />
      <.doc_link :if={@page?} path={@page_path} class="size-3.5" />
      <.complete_toggle :if={@f.status and not @page?} card={@card} size="size-3.5" />
      <p
        class={[
          "min-w-20 flex-1 truncate text-xs font-medium leading-snug",
          @card.completed && "text-base-content/50"
        ]}
        data-role="card-title"
        title={@card.title}
      >
        {@card.title}
      </p>
      <.card_id :if={@f.id and not @page?} card={@card} />
      <.favourite_mark :if={@favourite?} class="size-3" />
      <span
        :if={@f.tags}
        class="flex shrink-0 items-center gap-0.5"
        title={Enum.map_join(@card.tags, ", ", & &1.name)}
      >
        <span :for={tag <- @card.tags} class={["size-2 rounded-full", Palette.dot(tag.color)]}></span>
      </span>
      <.flag_icon :for={flag <- @card.flags} :if={@f.flags} flag={flag} card={@card} class="size-3" />
      <.dependency_badge :if={@f.dependencies} card={@card} class="size-3" />
      <.subcards_badge :if={@f.subcards} card={@card} open={not @page?} />
      <.waiting_chip
        :if={@f.waiting_chip}
        card={@card}
        items={@waiting.mine}
        id={"#{@dom_id}-waiting"}
      />
      <.stated_pill
        :if={@f.stated}
        health={Slipdock.Boards.Card.stated_health(@card)}
        with_label={false}
      />
      <SlipdockWeb.LoopComponents.loop_chip
        :if={@f.loop}
        id={"#{@dom_id}-loop"}
        loop={Slipdock.CardState.loop(@card)}
        href={SlipdockWeb.LoopComponents.job_href(@card, Slipdock.CardState.loop(@card))}
      />
      <.assignee_chips :if={@f.assignee} users={Slipdock.Boards.Card.assignees(@card)} size="xs" />
      <.priority_badge :if={@f.priority} priority={@card.priority} />
      <.date_range_badge :if={@f.range} card={@card} />
      <.start_badge :if={@f.start_date and not @f.range} card={@card} />
      <.schedule_badges :if={@f.due_date} card={@card} due={not @f.range} />
      <.percent_badge :if={@f.percent} percent={@card.percent_complete} />
      <.profile_chip
        :if={@f.profile}
        profile={@card.profile}
        source={Map.get(@card, :profile_source)}
      />
      <.time_badge :if={@f.time} card={@card} />
      <.handoff_mark :if={@f.handoff} handoff={@handoff} label={@handoff_label} class="size-3" />
      <.wait_mark :if={@f.wait} wait={@wait} class="size-3" compact />
      <.recurrence_mark :if={@f.recurrence} recurrence={@recurrence} class="size-3" />
      <.snooze_mark :if={@f.snoozed} card={@card} zone={@zone} />
      <.driver_mark :if={@f.driver} state={@state} class="size-3" />
      <.state_line :if={@f.state_line} state={@state} compact />
      <.age_chip :if={@f.age} state={@state} compact />
      <span :if={@actions != []} class="-mr-1 shrink-0">{render_slot(@actions)}</span>
    </div>
    """
  end

  # What in an epic's tree waits on the reader (#2095): the chip counts only
  # what is on them; the line names it, and what is on others, and takes the
  # percentage's place while it shows.
  defp waiting_marks(facets, waiting, glance) do
    Map.merge(facets, %{
      percent: facets.percent and is_nil(glance),
      waiting_chip: waiting.mine != [],
      waiting_line: not is_nil(glance)
    })
  end

  # What the board page put on the card for the tile (#2095); nothing
  # anywhere else.
  defp waiting_entry(card) do
    case Map.get(card, :waiting_on_me) do
      %{mine: _, others: _} = entry -> entry
      _ -> %{mine: [], others: []}
    end
  end

  attr :card, :map, required: true
  attr :items, :list, required: true
  attr :id, :string, required: true

  # `⏸ 2 waiting on you` (#2095): what in the epic's tree is on the reader.
  # It opens the sub-board kept to those cards; its own click, so the
  # card's doesn't open the card instead.
  defp waiting_chip(assigns) do
    assigns =
      assign(assigns,
        sub:
          match?(%Slipdock.Boards.Board{}, Map.get(assigns.card, :sub_board)) &&
            assigns.card.sub_board.id
      )

    ~H"""
    <.dynamic_tag
      id={@id}
      tag_name={if @sub, do: "button", else: "span"}
      phx-click={@sub && JS.navigate("/boards/#{@sub}?waiting=me")}
      data-role="waiting-chip"
      class="chip cursor-pointer bg-warning/15 text-warning hover:ring-1 hover:ring-current"
      title={Enum.map_join(@items, "\n", &"##{&1.card.id} #{&1.card.title}: #{&1.text}")}
    >
      ⏸ {length(@items)} waiting on you
    </.dynamic_tag>
    """
  end

  # The card's number on its front (#1856), quieter than the title.
  attr :card, :map, required: true

  defp card_id(assigns) do
    ~H"""
    <span
      data-role="card-id"
      class="shrink-0 text-xs font-normal tabular-nums leading-snug text-base-content/40"
      title={"Card ##{@card.id}"}
    >
      #{@card.id}
    </span>
    """
  end

  # The handoff itself on the card's front (#1171), when the Display menu asks
  # for it: the next step then the note, cut to two lines or in full.
  attr :handoff, :any, required: true
  attr :label, :string, required: true
  attr :mode, :string, required: true

  defp handoff_note(assigns) do
    assigns =
      assign(assigns,
        text: Enum.join([assigns.handoff.next_step | List.wrap(assigns.handoff.body)], "\n")
      )

    ~H"""
    <div
      class="rounded-lg bg-info/10 px-2 py-1.5 text-2xs leading-snug text-base-content/80"
      data-role="handoff-note"
      data-mode={@mode}
      title={if @mode == "short", do: @text}
    >
      <%!-- Unformatted: a line break here would show in the pre-line text. --%>
      <p phx-no-format class={["whitespace-pre-line break-words", @mode == "short" && "line-clamp-2"]}><span class="font-semibold text-info">{@label}:</span> {@text}</p>
    </div>
    """
  end

  attr :state, :any, required: true
  attr :compact, :boolean, default: false

  # What is happening to the card (#1117): the same words `card_line` and
  # the API give as `state`, coloured by what it is (#1132) so a running or
  # failed card stands out from the board around it.
  defp state_line(assigns) do
    {text, dot} = state_colours(assigns.state.kind)
    assigns = assign(assigns, text: text, dot: dot)

    ~H"""
    <p
      class={[
        "flex min-w-0 items-center gap-1 font-medium",
        @text,
        if(@compact, do: "max-w-40 shrink text-2xs", else: "text-2xs leading-snug")
      ]}
      data-role="state-line"
      data-kind={@state.kind}
      title={@state.line}
    >
      <span
        class={["size-1.5 shrink-0 rounded-full", @dot, @state.kind == "running" && "animate-pulse"]}
        aria-hidden="true"
      ></span>
      <span class="truncate">{@state.line}</span>
    </p>
    """
  end

  # The line's text and dot colours for each kind of state.
  defp state_colours("running"), do: {"text-success", "bg-success"}
  defp state_colours("claimed"), do: {"text-info", "bg-info"}
  defp state_colours("queued"), do: {"text-sky-700 dark:text-sky-300", "bg-sky-500"}

  defp state_colours(kind) when kind in ~w(waiting held),
    do: {"text-amber-700 dark:text-amber-300", "bg-amber-500"}

  defp state_colours(kind) when kind in ~w(failed timeout), do: {"text-error", "bg-error"}
  defp state_colours(_kind), do: {"text-base-content/70", "bg-base-content/40"}

  attr :state, :any, required: true
  attr :class, :string, default: "size-3.5"

  # Who is driving the card, on a tree where agents work (#1117).
  defp driver_mark(assigns) do
    ~H"""
    <span
      class={[
        "chip chip-icon chip-line",
        if(@state.driver == "agent", do: "text-secondary", else: "text-base-content/60")
      ]}
      data-role="driver-mark"
      data-driver={@state.driver}
      title={
        if @state.driver == "agent", do: "An agent is driving this", else: "A person is driving this"
      }
    >
      <.icon
        name={if @state.driver == "agent", do: "hero-cpu-chip", else: "hero-user"}
        class={@class}
      />
    </span>
    """
  end

  attr :state, :any, required: true
  attr :compact, :boolean, default: false

  @doc """
  How long the card has been in its list, amber past the list's usual stay:
  the tile's chip, and the open card's on its meta line (#2131).
  """
  def age_chip(assigns) do
    assigns = assign(assigns, :text, Slipdock.CardState.age_text(assigns.state))

    ~H"""
    <span
      class={[
        "chip shrink-0",
        if(@state.stuck,
          do: "bg-amber-500/15 text-amber-700 dark:text-amber-300",
          else: "chip-line text-base-content/60"
        )
      ]}
      data-role="age-chip"
      data-stuck={to_string(@state.stuck)}
      title={age_title(@state)}
    >
      {if @compact, do: Slipdock.Pulse.duration(@state.age), else: @text}
    </span>
    """
  end

  defp age_title(%{known: false} = state),
    do:
      "In this list for at most #{Slipdock.Pulse.duration(state.age)} (its move here wasn't recorded)"

  defp age_title(%{usual: nil} = state),
    do: "In this list for #{Slipdock.Pulse.duration(state.age)}"

  defp age_title(state),
    do:
      "In this list for #{Slipdock.CardState.age_text(state)}; usually " <>
        Slipdock.Pulse.duration(state.usual)

  attr :handoff, :any, required: true
  attr :label, :string, required: true
  attr :class, :string, default: "size-3.5"

  # A card someone stopped short on: the next step is the tooltip.
  defp handoff_mark(assigns) do
    ~H"""
    <span
      class="chip chip-icon chip-line text-info"
      data-role="handoff-mark"
      title={@label <> " — next: " <> @handoff.next_step}
    >
      <.icon name="hero-arrow-uturn-left" class={@class} />
    </span>
    """
  end

  attr :wait, :any, required: true
  attr :class, :string, default: "size-3.5"
  attr :compact, :boolean, default: false

  # A card waiting on a person (#1114): what it needs, and from whom.
  defp wait_mark(assigns) do
    ~H"""
    <span
      class="chip chip-tint max-w-full gap-1 text-warning"
      data-role="wait-mark"
      title={"Waiting on " <> Slipdock.Boards.Wait.on_name(@wait) <> ": " <> @wait.needs}
    >
      <.icon name="hero-hand-raised" class={@class} />
      <span :if={!@compact} class="truncate">{@wait.needs}</span>
    </span>
    """
  end

  # The runner loop's chip on a card's front (#2030): with the assignee
  # field, while a job holds the card. Apart from `card/1`, which is
  # already over credo's complexity limit.
  defp loop_on_face?(on, card),
    do: on.("assignee") and not is_nil(Slipdock.CardState.loop(card))

  attr :card, :any, required: true
  attr :zone, :string, default: "Etc/UTC"

  @doc "💤 and the day a snoozed card wakes (W-1803), the note as its tooltip."
  def snooze_mark(assigns) do
    ~H"""
    <span
      class="chip chip-line shrink-0 text-base-content/70"
      data-role="snooze-mark"
      title={snooze_title(@card, @zone)}
    >
      <span aria-hidden="true" class="leading-none">💤</span>
      {Dates.short(@card.snoozed_until, zone: @zone)}
      <span class="sr-only">Snoozed</span>
    </span>
    """
  end

  defp snooze_title(card, zone) do
    until = "Snoozed until " <> Dates.exact(card.snoozed_until, zone: zone)
    if card.snooze_note, do: until <> " — " <> card.snooze_note, else: until
  end

  attr :recurrence, :any, required: true
  attr :class, :string, default: "size-3.5"

  defp recurrence_mark(assigns) do
    ~H"""
    <span
      class="chip chip-icon chip-line text-primary"
      data-role="recurrence-mark"
      title={recurrence_title(@recurrence)}
    >
      <span aria-hidden="true" class="leading-none">↻</span>
      <span class="sr-only">Repeats</span>
    </span>
    """
  end

  defp recurrence_title(series) do
    state =
      cond do
        series.ended_at -> " — ended"
        series.paused -> " — paused"
        series.next_on -> " — next due #{Dates.weekday(series.next_on)}"
        true -> ""
      end

    "Repeats: " <> Slipdock.Recurrence.Series.summary(series) <> state
  end

  # A card or a placed page the reader has favourited. Only a mark, not the
  # toggle: a click on the front of the card opens it.
  defp favourite_mark?(nil, _card), do: false

  defp favourite_mark?(marks, card),
    do: Slipdock.Favourites.favourite?(marks, if(page?(card), do: :page, else: :card), card.id)

  attr :class, :string, default: "size-3.5"

  defp favourite_mark(assigns) do
    ~H"""
    <span class="shrink-0 text-rose-500" data-role="favourite-mark" title="In your favourites">
      <.icon name="hero-heart-solid" class={@class} />
      <span class="sr-only">Favourite</span>
    </span>
    """
  end

  ## Placed wiki pages --------------------------------------------------------

  @doc """
  Whether a thing drawn on a board is a wiki page rather than a card.

  A placed page carries the card's facets under the card's names (see
  `Slipdock.Wiki.Page`), so everything that *reads* one treats them alike. This
  is for the handful of places that must not: the link that opens the
  document, and the `page-7` id the drag-and-drop needs.
  """
  def page?(%Slipdock.Wiki.Page{}), do: true
  def page?(_), do: false

  @doc """
  The path of a placed page's document: what its tile's document icon links
  to, in every view that draws one.
  """
  def page_path(%Slipdock.Wiki.Page{board_id: board_id, slug: slug}),
    do: ~p"/boards/#{board_id}/wiki/#{slug}"

  @doc """
  The id a card or a placed wiki page answers to on the board: `page-7` for a
  page, a bare number for a card.

  Two id spaces share one list, so everything that puts an item's id into the
  DOM or onto the wire uses this — the drag-and-drop reads it back with
  `Slipdock.Boards.Columns.item_ref/1`, and a card and a page that happen to share a
  number never collide.
  """
  def item_id(item), do: if(page?(item), do: "page-#{item.id}", else: to_string(item.id))

  @doc """
  The document icon on a placed page's tile: one click opens the page.

  It is a link rather than a button, and it sits *outside* the tile's own
  click target, so opening the document and opening the panel never race each
  other for the same click. That is the whole bargain of a page on the board:
  the icon is the document, the rest of it is a card.
  """
  attr :path, :string, required: true
  attr :class, :string, default: "size-4"

  def doc_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class="shrink-0 text-primary/70 transition hover:text-primary"
      title="Open the document"
      aria-label="Open the document"
    >
      <.icon name="hero-document-text" class={@class} />
    </.link>
    """
  end

  @doc """
  The icon for a kind of thing in a list (see `Slipdock.Kinds`): a card, a
  document — a card whose whole content is the file clipped to it — or a wiki
  page placed in the list.
  """
  def kind_icon("document"), do: "hero-paper-clip"
  def kind_icon("page"), do: "hero-document-text"
  def kind_icon(_card), do: "hero-rectangle-stack"

  # A stand-in: what sprint planning leaves where a card it took used to be.
  # Nothing on it is its own — the title, the sprint and the status are the
  # real card's, read as the board loads — and opening it opens that card.
  defp stand_in_card(assigns) do
    target = loaded(assigns.card.stand_in_for)
    {label, class, icon} = stand_in_status(target)

    assigns =
      assign(assigns,
        title: (target && target.title) || assigns.card.title,
        where: stand_in_where(target),
        label: label,
        status_class: class,
        status_icon: icon
      )

    ~H"""
    <div
      id={@id || "card-#{@card.id}"}
      data-id={@card.id}
      data-stand-in={@card.stand_in_for_id}
      class={[
        "kanban-card kanban-stand-in group relative cursor-grab rounded-xl border border-dashed",
        "border-base-content/20 bg-base-100/60 outline-none transition",
        "hover:border-primary/40 hover:bg-base-100 active:cursor-grabbing",
        "focus-visible:ring-2 focus-visible:ring-primary/50",
        @focus == :cursor && "z-10 ring-2 ring-secondary",
        @focus == :held && "z-10 scale-[1.02] shadow-lg ring-2 ring-primary"
      ]}
      data-focus={@focus}
      tabindex="0"
      role="button"
      title={"Stand-in: this card moved to #{@where || "another board"}. Open it there."}
      phx-click={JS.push("open_card", value: %{id: @card.id})}
      phx-keydown={JS.push("open_card", value: %{id: @card.id})}
      phx-key="Enter"
    >
      <div class={["flex items-center gap-2 px-2.5", if(@compact, do: "py-1.5", else: "pt-2")]}>
        <.icon name="hero-arrow-uturn-right" class="size-3.5 shrink-0 text-base-content/40" />
        <p
          class={[
            "min-w-0 flex-1 truncate font-medium leading-snug text-base-content/70",
            if(@compact, do: "text-2xs", else: "text-xs")
          ]}
          title={@title}
        >
          {@title}
        </p>
        <span
          :if={@compact}
          class={["chip shrink-0 text-2xs", @status_class]}
          title={stand_in_summary(@where, @label)}
        >
          <.icon name={@status_icon} class="size-3" />
        </span>
        <span :if={@actions != []} class="-mr-1 shrink-0">{render_slot(@actions)}</span>
        <button
          :if={@dismiss}
          type="button"
          class="-mr-1 shrink-0 rounded p-0.5 text-base-content/30 opacity-0 transition hover:text-base-content group-hover:opacity-100 focus-visible:opacity-100"
          phx-click={JS.push("dismiss_stand_in", value: %{id: @card.id})}
          title="Dismiss this stand-in"
          aria-label={"Dismiss the stand-in for #{@title}"}
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
      <div :if={!@compact} class="flex flex-wrap items-center gap-1 px-2.5 pt-1 pb-2 text-2xs">
        <span :if={@where} class="chip chip-line max-w-40 truncate text-base-content/60">
          <.icon name="hero-arrow-right" class="size-3" /> {@where}
        </span>
        <span class={["chip", @status_class]}>
          <.icon name={@status_icon} class="size-3" /> {@label}
        </span>
      </div>
    </div>
    """
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded(value), do: value

  # Where the real card is now: the sprint holding it, or the board when it
  # has gone somewhere that is not a sprint's.
  defp stand_in_where(nil), do: nil

  defp stand_in_where(%{board: board}) do
    case loaded(board) do
      nil -> nil
      %{parent_card: parent} = board -> (loaded(parent) && parent.title) || board.name
    end
  end

  defp stand_in_summary(nil, label), do: label
  defp stand_in_summary(where, label), do: "#{where} · #{label}"

  # The real card's status, from its list's category rather than its list's
  # name: the two boards' lists need not match, but every board knows what
  # to-do, doing and done mean.
  @stand_in_statuses %{
    deleted: {"Deleted", "chip-line text-base-content/50", "hero-trash"},
    archived: {"Archived", "chip-line text-base-content/50", "hero-archive-box"},
    done: {"Done", "bg-success/15 text-success", "hero-check-circle"},
    doing: {"In progress", "bg-sky-500/15 text-sky-700 dark:text-sky-300", "hero-play-circle"},
    dropped: {"Dropped", "chip-line text-base-content/50", "hero-x-circle"},
    todo: {"To do", "chip-line text-base-content/70", "hero-stop-circle"}
  }

  @doc "The status a stand-in shows for the card it stands for, as `{label, class, icon}`."
  def stand_in_status(target), do: Map.fetch!(@stand_in_statuses, stand_in_state(target))

  @doc "The same, as a word: deleted, archived, done, doing, dropped or todo."
  def stand_in_state(nil), do: :deleted
  def stand_in_state(%{archived_at: at}) when not is_nil(at), do: :archived

  def stand_in_state(target) do
    case loaded(Map.get(target, :column)) do
      %{category: "done"} -> :done
      %{category: "doing"} -> :doing
      %{category: "dropped"} -> :dropped
      _ -> if target.completed, do: :done, else: :todo
    end
  end

  @doc """
  The click that opens an item: a card opens the card, a placed wiki page opens
  its panel, which the view turns into a query parameter so it works over every
  mode without a route each.

  Every view that draws cards and placed pages together needs this — a page
  pushed at `open_card` is a card that "no longer exists".
  """
  def open_item(item), do: open_item(page?(item), item.id)

  defp open_item(true, id), do: JS.push("open_page", value: %{id: id})
  defp open_item(false, id), do: JS.push("open_card", value: %{id: id})
end

defmodule SlipdockWeb.BoardLive.CardPanel.Properties do
  @moduledoc """
  The card panel's property rows (assignees, priority, dates, health), who
  made the card and changed it last, and the colours of its borders. Drawn
  by `BoardLive.CardPanel`'s sidebar and its phone summary, which pass each
  the assigns it reads, by name.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents

  alias Slipdock.Boards.Card
  alias Slipdock.{Dates, Palette}

  @border_edges [
    {"all", "All", nil},
    {"top", "Top", :border_top},
    {"right", "Right", :border_right},
    {"bottom", "Bottom", :border_bottom},
    {"left", "Left", :border_left}
  ]

  attr :card, :map, required: true
  attr :target, :any, required: true

  @doc """
  A colour for each edge of the card's front (#1209), apart from its cover:
  a row of swatches per edge, and an "All" row that sets the four at once.
  Folded away until opened, unless the card already has one.
  """
  def borders_section(assigns) do
    card = assigns.card
    colours = Enum.map(Slipdock.Boards.Card.borders(), &Map.get(card, &1))
    same = if Enum.uniq(colours) |> length() == 1, do: hd(colours), else: :mixed

    assigns =
      assign(assigns,
        edges: @border_edges,
        any?: Enum.any?(colours),
        same: same
      )

    ~H"""
    <details id="card-borders" class="group space-y-1.5" open={@any?}>
      <summary class="cursor-pointer list-none section-label">
        Borders <.icon name="hero-chevron-down" class="size-3 transition group-open:rotate-180" />
      </summary>
      <div :for={{edge, label, field} <- @edges} class="flex items-center gap-2 pt-1.5">
        <span class="w-11 shrink-0 text-xs text-base-content/60">{label}</span>
        <div class="flex flex-wrap gap-1">
          <.color_swatch
            phx-target={@target}
            color={nil}
            label={"No #{String.downcase(label)} border"}
            selected={edge_colour(@card, field, @same) == nil}
            phx-click="set_border"
            phx-value-edge={edge}
            phx-value-color=""
            class="size-5"
          />
          <.color_swatch
            :for={{name, _} <- Palette.all()}
            phx-target={@target}
            color={name}
            selected={edge_colour(@card, field, @same) == name}
            phx-click="set_border"
            phx-value-edge={edge}
            phx-value-color={name}
            class="size-5"
          />
        </div>
      </div>
    </details>
    """
  end

  # The "All" row shows a colour only when the four edges agree on it.
  defp edge_colour(_card, nil, same), do: if(same == :mixed, do: :mixed, else: same)
  defp edge_colour(card, field, _same), do: Map.get(card, field)

  # Whether the reader's card view shows a sidebar property (#2070): nil, a
  # panel drawn with no card view, shows them all.
  @doc false
  def side?(nil, _key), do: true
  def side?(panel, key), do: MapSet.member?(panel, key)

  attr :name, :string, required: true, doc: "`data-prop`, for tests and the e2e script"
  attr :label, :string, required: true
  attr :for, :string, default: nil, doc: "the id of the value's own input, if it has one"
  attr :icon, :string, default: nil, doc: "a heroicon drawn before the label"
  attr :rest, :global
  slot :inner_block, required: true

  # One property on the card back (#1726): the label on the left, the value
  # on the right.
  defp prop_row(assigns) do
    ~H"""
    <div
      data-prop={@name}
      class="grid min-h-8 grid-cols-[5.5rem_minmax(0,1fr)] items-center gap-x-2"
      {@rest}
    >
      <label
        :if={@for}
        for={@for}
        data-role="prop-label"
        class="flex min-w-0 items-center gap-1 text-xs text-base-content/60"
      >
        <.icon :if={@icon} name={@icon} class="size-3.5 shrink-0" />
        <span class="truncate">{@label}</span>
      </label>
      <span
        :if={!@for}
        data-role="prop-label"
        class="flex min-w-0 items-center gap-1 text-xs text-base-content/60"
      >
        <.icon :if={@icon} name={@icon} class="size-3.5 shrink-0" />
        <span class="truncate">{@label}</span>
      </span>
      <div data-role="prop-value" class="min-w-0 text-sm">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :card, Card, required: true

  defp precision_row(assigns) do
    ~H"""
    <.prop_row name="precision" label="Precision" for="card-precision">
      <select name="card[date_precision]" class="select field-bare w-full" id="card-precision">
        <option
          :for={{key, label} <- Dates.precisions()}
          value={key}
          selected={key == (@card.date_precision || "day")}
        >
          {label}
        </option>
      </select>
    </.prop_row>
    <p :if={Card.fuzzy?(@card) and @card.due_date} class="pl-24 text-xs text-base-content/60">
      Scheduled for {Dates.range_label(
        @card.start_date || @card.due_date,
        @card.due_date,
        @card.date_precision
      )}
    </p>
    """
  end

  attr :board, :any, required: true
  attr :card, Card, required: true
  attr :loop, :map, default: nil, doc: "the runner loop holding the card (#2027)"
  attr :authors, :map, default: nil, doc: "who created it and changed it last (#2028)"
  attr :form, :any, required: true
  attr :target, :any, required: true
  attr :users, :list, required: true

  attr :panel, :any,
    default: nil,
    doc: "the properties the reader's card view shows (#2070), a MapSet; nil shows them all"

  @doc """
  The card's properties (#1726) as label/value rows, the value bare until it
  is pointed at or focused. The list and Completed are not here: the meta
  line and the title's check are where those are changed. Drawn inside a
  form that sends `card_change`: the sidebar's, or on a phone the one under
  the title (`phone_properties/1`), never both.
  """
  def card_props(assigns) do
    ~H"""
    <div id="card-props" class="space-y-0.5">
      <.prop_row
        :if={side?(@panel, "side.assignees")}
        name="assignees"
        label="Assignees"
        id="card-assignees"
      >
        <div class="flex min-w-0 flex-wrap items-center gap-1">
          <%!-- The runner loop holding the card (#2027): beside the people,
                never one of them, and gone when its job ends. --%>
          <SlipdockWeb.LoopComponents.loop_chip
            id="card-assignee-loop"
            loop={@loop}
            href={@loop && "#card-job-#{@loop.job_id}"}
          />
          <span
            :for={u <- Card.assignees(@card)}
            id={"card-assignee-#{u.id}"}
            class="inline-flex min-w-0 max-w-full items-center gap-1 rounded-full bg-base-200 py-0.5 pr-1 pl-0.5 [&>span:first-child]:min-w-0"
          >
            <.assignee_chip user={u} size="xs" with_name />
            <button
              phx-target={@target}
              type="button"
              phx-click="remove_assignee"
              phx-value-id={u.id}
              class="rounded-full p-0.5 text-base-content/50 transition hover:bg-base-300 hover:text-base-content"
              title={"Unassign #{Slipdock.Accounts.User.display_name(u)}"}
            >
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </span>
          <%!-- Keyed on who is already on the card, so the picker comes
                back empty after each pick instead of re-sending the
                last one. --%>
          <select
            name="card[add_assignee_id]"
            class="select field-bare w-full min-w-0 flex-1 text-base-content/70"
            aria-label="Add an assignee"
            id={"card-assignee-add-" <> Enum.map_join(Card.assignees(@card), "-", & &1.id)}
          >
            <option value="" selected>
              {if Card.assignees(@card) == [], do: "Unassigned", else: "Add…"}
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
      </.prop_row>
      <.prop_row
        :if={side?(@panel, "side.priority")}
        name="priority"
        label="Priority"
        for="card-priority"
      >
        <select
          name="card[priority]"
          id="card-priority"
          class="select field-bare w-full"
        >
          <option
            :for={{label, value} <- priority_options()}
            value={value}
            selected={value == @card.priority}
          >
            {label}
          </option>
        </select>
      </.prop_row>
      <%!-- A simple board is a to-do list: % complete, Start, Precision
            and Health are project tracking, and stay out of its way
            (`Board.simple?/1`). --%>
      <.prop_row
        :if={not @board.simple and side?(@panel, "side.percent")}
        name="percent"
        label="% complete"
        for="card-percent-complete"
      >
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
            class="input field-bare w-16"
          />
          <progress
            :if={@card.percent_complete}
            class={[
              "progress h-1.5 min-w-0 flex-1",
              if(@card.percent_complete == 100,
                do: "progress-success",
                else: "progress-primary"
              )
            ]}
            value={@card.percent_complete}
            max="100"
          ></progress>
        </div>
      </.prop_row>
      <p :if={@form[:percent_complete].errors != []} class="text-xs text-error">
        Use a whole number from 0 to 100.
      </p>
      <.prop_row
        :if={not @board.simple and side?(@panel, "side.start")}
        name="start"
        label="Start"
        icon={start_icon()}
      >
        <.date_field
          id={"card-start-date-#{@card.id}"}
          name="card[start_date]"
          value={@card.start_date}
          max={@card.due_date}
          bare
          class="w-full"
          aria-label="Start date"
        />
      </.prop_row>
      <%!-- The start in words (#1709): "Starts in 11 days", "Started 11
            days late". --%>
      <p
        :if={
          (not @board.simple and side?(@panel, "side.start") and @card.start_date) &&
            start_words(@card)
        }
        class="pl-24 text-xs text-base-content/60"
        data-role="start-words"
      >
        {start_words(@card)}
      </p>
      <.prop_row :if={side?(@panel, "side.due")} name="due" label="Due" icon={due_icon()}>
        <div class="flex min-w-0 flex-wrap items-center gap-1">
          <.date_field
            id={"card-due-date-#{@card.id}"}
            name="card[due_date]"
            value={@card.due_date}
            min={@card.start_date}
            bare
            class="min-w-0 flex-1"
            aria-label="Due date"
          />
          <%!-- The date is in the field: the badge only when it says
                more (overdue, due soon, done). --%>
          <.due_badge
            :if={due_state(@card.due_date, @card.completed) not in [nil, :later]}
            date={@card.due_date}
            completed={@card.completed}
          />
        </div>
      </.prop_row>
      <p :if={@form[:start_date].errors != []} class="text-xs text-error">
        Start must be on or before the due date.
      </p>
      <%!-- Precision matters only once it isn't "day": until then it is
            under More (a toggle the client keeps across patches). --%>
      <.precision_row
        :if={
          not @board.simple and side?(@panel, "side.precision") and
            (@card.date_precision || "day") != "day"
        }
        card={@card}
      />
      <.prop_row
        :if={not @board.simple and side?(@panel, "side.health")}
        name="health"
        label="Health"
        id="card-status"
      >
        <div
          class="flex flex-wrap items-center gap-1.5"
          aria-describedby="card-health-about"
        >
          <.health_pill health={Card.health(@card)} />
          <.stated_pill
            :if={Card.stated_health(@card)}
            health={Card.stated_health(@card)}
            title="Last reported on the card"
          />
          <span
            id="card-health-about"
            class="inline-flex text-base-content/50"
            title={health_about(Card.stated_health(@card))}
          >
            <.icon name="hero-information-circle" class="size-4" />
            <span class="sr-only">{health_about(Card.stated_health(@card))}</span>
          </span>
        </div>
      </.prop_row>
      <div :if={
        not @board.simple and side?(@panel, "side.precision") and
          (@card.date_precision || "day") == "day"
      }>
        <button
          type="button"
          id="card-props-more-toggle"
          aria-expanded="false"
          aria-controls="card-props-more"
          phx-click={
            JS.toggle_attribute({"hidden", "hidden"}, to: "#card-props-more")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
          class="btn btn-ghost btn-xs gap-1 px-1 font-normal text-base-content/60"
        >
          More <.icon name="hero-chevron-down" class="size-3" />
        </button>
        <div id="card-props-more" hidden>
          <.precision_row card={@card} />
        </div>
      </div>
      <.card_authors
        :if={@authors && side?(@panel, "side.authors")}
        authors={@authors}
        origin={Slipdock.Origin.label(@card.origin, @card.origin_job_id)}
      />
    </div>
    """
  end

  attr :authors, :map, required: true
  attr :origin, :string, default: nil, doc: "where the card came from (#2778), or nil"

  # Who made the card and who changed it last (#2028), read-only, under its
  # properties: "Created by Robin, 3 days ago", "Last changed by Dev server
  # loop, 2 minutes ago". Nobody recorded is the time alone, never a guess.
  defp card_authors(assigns) do
    ~H"""
    <div id="card-authors" class="space-y-0.5 px-1 pt-2 text-xs text-base-content/50">
      <p id="card-created-by">
        <.author_line
          verb="Created"
          who={@authors.created_by}
          at={@authors.created_at}
          id="card-created-by-at"
        />
      </p>
      <p :if={@origin} id="card-origin" data-origin={@origin}>
        Origin <span class="font-medium text-base-content/70">{@origin}</span>
      </p>
      <p id="card-changed-by">
        <.author_line
          verb="Last changed"
          who={@authors.updated_by}
          at={@authors.updated_at}
          id="card-changed-by-at"
        />
      </p>
    </div>
    """
  end

  attr :verb, :string, required: true
  attr :who, :map, default: nil
  attr :at, :any, required: true
  attr :id, :string, required: true

  defp author_line(%{who: nil} = assigns) do
    ~H"""
    {@verb} <.timestamp id={@id} at={@at} />
    """
  end

  defp author_line(assigns) do
    ~H"""
    {@verb} by <span class="font-medium text-base-content/70" data-author-kind={@who.kind}>{@who.name}</span>,
    <.timestamp
      id={@id}
      at={@at}
    />
    """
  end

  # The Health pills' tooltip (#1699): what each one means, kept off the page.
  defp health_about(nil), do: "Worked out from the card's dates, blockers and subcards."

  defp health_about(_stated),
    do:
      "The first is worked out from the card's dates, blockers and subcards. " <>
        "The second is what was last reported."
end

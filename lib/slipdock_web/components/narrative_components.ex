defmodule SlipdockWeb.NarrativeComponents do
  @moduledoc """
  The narrative view: a readable account of what happened to the cards a
  view selects over a date range, group by group, card by card.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  alias Slipdock.Boards.Card
  alias SlipdockWeb.RichText
  alias Slipdock.Palette
  alias Slipdock.Swimlanes.Config

  attr :board, :any, required: true
  attr :config, Config, required: true
  attr :narrative, :map, required: true, doc: "from Slipdock.Narrative.build/3"
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed group keys"
  attr :can_write, :boolean, default: true
  attr :view_name, :string, default: nil
  attr :ai, :boolean, default: false, doc: "offer the AI narrative generator"
  attr :current_user, :any, default: nil, doc: "whose OpenRouter key the generator spends"

  def narrative_view(assigns) do
    n = assigns.narrative
    assigns = assign(assigns, s: n.summary, range: range_label(n.from, n.to), tell: n.tell)

    ~H"""
    <div id="narrative-scroll" class="kanban-scroll h-full overflow-auto">
      <article id="narrative" class="mx-auto max-w-3xl space-y-8 px-6 py-8 print:max-w-none">
        <header class="space-y-3">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            {@board.name}<span :if={@view_name}> · {@view_name}</span>
          </p>
          <h1 class="text-2xl font-semibold tracking-tight">What happened, {@range}</h1>
          <p class="text-sm leading-relaxed text-base-content/80">
            <%= if @s.cards == 0 do %>
              No cards match this view.
            <% else %>
              <strong>{@s.changed} of {@s.cards}</strong>
              {if @s.cards == 1, do: "card", else: "cards"} changed<span :if={@s.events > 0}>:
                {Enum.join(happenings(@s), ", ")}</span>.
              <span :if={@s.overdue_now + @s.blocked_now + @s.at_risk_now > 0}>
                Right now {Enum.join(
                  Enum.reject(
                    [
                      if(@s.overdue_now > 0, do: "#{@s.overdue_now} overdue"),
                      if(@s.blocked_now > 0, do: "#{@s.blocked_now} blocked"),
                      if(@s.at_risk_now > 0, do: "#{@s.at_risk_now} at risk")
                    ],
                    &is_nil/1
                  ),
                  ", "
                )}.
              </span>
              <span :if={@s.done_now == @s.cards}>Everything here is done.</span>
            <% end %>
          </p>
          <div
            :if={
              MapSet.member?(@tell, "milestones") and
                (@narrative.milestones.passed != [] or @narrative.milestones.upcoming != [])
            }
            class="flex flex-wrap gap-x-4 gap-y-1 text-xs"
          >
            <span :for={m <- @narrative.milestones.passed} class="flex items-center gap-1.5">
              <span class={["size-2 rotate-45", Palette.dot(m.color || "indigo")]}></span>
              <strong>{m.name}</strong> passed on {fmt(m.date)}
            </span>
            <span
              :for={m <- @narrative.milestones.upcoming}
              class="flex items-center gap-1.5 text-base-content/70"
            >
              <span class={["size-2 rotate-45", Palette.dot(m.color || "indigo")]}></span>
              {m.name} coming up on {fmt(m.date)}
            </span>
          </div>
          <.live_component
            :if={@ai and @s.cards > 0}
            module={SlipdockWeb.NarrativeGeneratorComponent}
            id="narrative-generator"
            current_user={@current_user}
            board={@board}
            narrative={@narrative}
            view_name={@view_name}
          />
          <div
            :if={@narrative.shown == 0 and @narrative.hidden > 0}
            class="rounded-lg bg-base-200/60 p-3 text-sm text-base-content/60"
          >
            No cards match the current filters.
            <button
              :if={Config.filtering?(@config)}
              type="button"
              class="btn btn-xs ml-2"
              phx-click="swim_clear_filters"
            >
              Clear filters
            </button>
          </div>
        </header>

        <section :for={group <- @narrative.groups} class="space-y-4">
          <% collapsed = MapSet.member?(@collapsed, group.key) %>
          <h2
            :if={@narrative.grouped}
            class="flex cursor-pointer items-center gap-2 border-b border-base-300 pb-1 text-lg font-semibold"
            phx-click="swim_toggle_row"
            phx-value-key={group.key}
            role="button"
            tabindex="0"
          >
            <.icon
              name={if collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
              class="size-4 text-base-content/50 print:hidden"
            />
            <span :if={group.color} class={["size-2.5 rounded-full", Palette.dot(group.color)]}></span>
            {group.label}
            <span class="text-sm font-normal text-base-content/50">
              {group.changed} of {group.total} changed
            </span>
          </h2>

          <div :if={not collapsed} class="space-y-5">
            <.card_story
              :for={entry <- group.cards}
              :if={entry.changed?}
              entry={entry}
              board={@board}
              today={@narrative.today}
              tell={@tell}
            />
            <% unchanged = Enum.reject(group.cards, & &1.changed?) %>
            <p
              :if={unchanged != [] and MapSet.member?(@tell, "unchanged")}
              class="text-xs leading-relaxed text-base-content/50"
            >
              <span class="font-semibold">Unchanged:</span>
              <span :for={{entry, i} <- Enum.with_index(unchanged)}>
                <span
                  role="link"
                  tabindex="0"
                  class="cursor-pointer hover:underline"
                  phx-click={open_item(entry.card)}
                >{entry.card.title}</span><span :if={i < length(unchanged) - 1}>, </span>
              </span>
            </p>
          </div>
        </section>

        <section :if={@narrative.board_events != []} class="space-y-2">
          <h2 class="border-b border-base-300 pb-1 text-lg font-semibold">Board changes</h2>
          <ul class="space-y-1 text-sm">
            <li :for={e <- @narrative.board_events} class="flex gap-3">
              <span class="w-28 shrink-0 text-xs text-base-content/50">{fmt_at(e.at)}</span>
              <span>{e.message}</span>
            </li>
          </ul>
        </section>
      </article>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :board, :any, required: true
  attr :today, :any, required: true
  attr :tell, :any, required: true, doc: "MapSet of the config's tell keys"

  defp card_story(assigns) do
    card = assigns.entry.card
    column = Enum.find(assigns.board.columns, &(&1.id == card.column_id))

    assigns =
      assign(assigns,
        card: card,
        column: column,
        foreign: card.board_id != assigns.board.id,
        progress: Card.progress(card),
        summary?: MapSet.member?(assigns.tell, "summary"),
        comment_text?: MapSet.member?(assigns.tell, "comment_text")
      )

    ~H"""
    <div id={"story-#{item_id(@card)}"} class="space-y-1.5">
      <div class="flex flex-wrap items-center gap-2">
        <h3
          class={[
            "cursor-pointer text-sm font-semibold hover:underline",
            @card.completed && "text-base-content/60"
          ]}
          phx-click={open_item(@card)}
          role="link"
          tabindex="0"
        >
          {@card.title}
        </h3>
        <span :if={not is_nil(@column) and not @summary?} class="chip chip-line text-2xs">{@column.name}</span>
        <.health_pill :if={Card.health(@card) not in [nil, :ok]} health={Card.health(@card)} />
        <.stated_pill :if={Card.stated_health(@card)} health={Card.stated_health(@card)} />
        <span
          :if={not @summary? and @progress}
          class="chip chip-line text-2xs font-mono"
        >
          {elem(@progress, 0)}/{elem(@progress, 1)}
        </span>
        <.due_badge
          :if={not @summary?}
          date={Card.effective_due(@card)}
          completed={@card.completed}
          derived={Card.due_derived?(@card)}
        />
      </div>
      <.card_summary :if={@summary?} card={@card} column={@column} />
      <ul class="space-y-0.5 text-sm">
        <li :for={e <- @entry.events} class="flex gap-3">
          <span
            class="w-28 shrink-0 text-xs leading-5 text-base-content/50"
            title={DateTime.to_iso8601(e.at)}
          >
            {fmt_at(e.at)}
          </span>
          <span class="flex min-w-0 items-start gap-1.5">
            <.icon name={event_icon(e.kind)} class={["mt-1 size-3.5 shrink-0", event_tone(e.kind)]} />
            <span class={["min-w-0", !e.own? && "text-base-content/80"]}>
              <span :if={!e.own?} class="mr-1 text-base-content/40" title="On a subcard">↳</span>{e.message}
              <span
                :if={@comment_text? and e.kind == :comment and e[:body]}
                class="mt-0.5 block whitespace-pre-wrap break-words border-l-2 border-base-300 pl-2 text-base-content/70"
                phx-no-format
              >{RichText.render(e.body)}</span>
            </span>
          </span>
        </li>
      </ul>
    </div>
    """
  end

  attr :card, Card, required: true
  attr :column, :any, required: true

  # The card as it stands now: the values a reader would otherwise open the card for.
  defp card_summary(assigns) do
    card = assigns.card
    checklist = if is_list(card.checklist_items), do: card.checklist_items, else: []

    assigns =
      assign(assigns,
        progress: Card.progress(card),
        start: Card.effective_start(card),
        due: Card.effective_due(card),
        assignees: Card.assignees(card),
        checklist: {Enum.count(checklist, & &1.done), length(checklist)},
        votes: Card.vote_total(card),
        tags: if(is_list(card.tags), do: card.tags, else: [])
      )

    ~H"""
    <dl class="flex flex-wrap gap-x-5 gap-y-1 rounded-lg bg-base-200/50 px-3 py-2 text-xs">
      <.summary_item :if={@column} label="List">{@column.name}</.summary_item>
      <.summary_item label="Status">
        {if @card.completed, do: "Done", else: "Open"}
      </.summary_item>
      <.summary_item :if={@card.priority != "none"} label="Priority">
        <.priority_badge priority={@card.priority} />
      </.summary_item>
      <.summary_item
        :if={@assignees != []}
        label={if length(@assignees) > 1, do: "Assignees", else: "Assignee"}
      >
        <.assignee_chips users={@assignees} size="xs" with_name />
      </.summary_item>
      <.summary_item :if={@start} label="Start">
        {fmt(@start)}<span :if={Card.start_derived?(@card)} title="From the subcards">*</span>
      </.summary_item>
      <.summary_item :if={@due} label="Due">
        <.due_badge date={@due} completed={@card.completed} derived={Card.due_derived?(@card)} />
      </.summary_item>
      <.summary_item :if={@progress} label="Progress">
        <% {done, total} = @progress %>
        <span class="font-mono">{done}/{total}</span>
        <span :if={total > 0} class="text-base-content/50">· {div(done * 100, total)}%</span>
      </.summary_item>
      <.summary_item :if={elem(@checklist, 1) > 0} label="Checklist">
        <span class="font-mono">{elem(@checklist, 0)}/{elem(@checklist, 1)}</span>
      </.summary_item>
      <.summary_item :if={Card.health(@card) not in [nil, :ok]} label="Health">
        <.health_pill health={Card.health(@card)} />
      </.summary_item>
      <.summary_item :if={Card.stated_health(@card)} label="Reported">
        <.stated_pill health={Card.stated_health(@card)} />
      </.summary_item>
      <.summary_item :if={@tags != []} label="Tags">
        <span class="flex flex-wrap gap-1">
          <.tag_chip :for={tag <- @tags} tag={tag} size="xs" />
        </span>
      </.summary_item>
      <.summary_item :if={@card.flags != []} label="Flags">
        <span class="flex gap-1"><.flag_icon :for={flag <- @card.flags} flag={flag} class="size-3.5" /></span>
      </.summary_item>
      <.summary_item :if={@votes > 0} label="Votes">{@votes}</.summary_item>
    </dl>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp summary_item(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <dt class="font-semibold uppercase tracking-wide text-base-content/50">{@label}</dt>
      <dd class="flex items-center gap-1">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp happenings(s) do
    [
      {s.created, "added"},
      {s.completed, "completed"},
      {s.reopened, "reopened"},
      {s.moved, "moved"},
      {s.scheduled, "rescheduled"},
      {s.comments, "commented on"},
      {s.status_updates, "status updates"},
      {s.votes, "votes"}
    ]
    |> Enum.filter(fn {n, _} -> n > 0 end)
    |> Enum.map(fn {n, what} -> "#{n} #{what}" end)
  end

  defp event_icon(:created), do: "hero-plus-circle"
  defp event_icon(:completed), do: "hero-check-circle"
  defp event_icon(:reopened), do: "hero-arrow-uturn-left"
  defp event_icon(:moved), do: "hero-arrow-right-circle"
  defp event_icon(:due), do: "hero-calendar"
  defp event_icon(:start), do: "hero-calendar"
  defp event_icon(:comment), do: "hero-chat-bubble-left"
  defp event_icon(:status), do: "hero-hand-raised"
  defp event_icon(:vote), do: "hero-hand-thumb-up"
  defp event_icon(:archived), do: "hero-archive-box"
  defp event_icon(:attached), do: "hero-paper-clip"
  defp event_icon(:assigned), do: "hero-user"
  defp event_icon(_), do: "hero-pencil"

  defp event_tone(:completed), do: "text-success"
  defp event_tone(:created), do: "text-primary"
  defp event_tone(:status), do: "text-amber-600 dark:text-amber-300"
  defp event_tone(_), do: "text-base-content/40"

  defp fmt(%Date{} = d), do: Calendar.strftime(d, "%-d %b %Y")
  defp fmt_at(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %-d %b")

  defp range_label(from, to) do
    cond do
      from == to -> fmt(from)
      from.year == to.year and from.month == to.month -> "#{from.day}–#{fmt(to)}"
      from.year == to.year -> "#{Calendar.strftime(from, "%-d %b")} – #{fmt(to)}"
      true -> "#{fmt(from)} – #{fmt(to)}"
    end
  end
end

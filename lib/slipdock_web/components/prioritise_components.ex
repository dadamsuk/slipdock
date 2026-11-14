defmodule SlipdockWeb.PrioritiseComponents do
  @moduledoc """
  The prioritise view: a ranked table where priority, votes and every
  scoring field are edited in place (see `Slipdock.Prioritise`).
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ItemComponents, only: [field_input: 1]
  alias Slipdock.Boards.{Card, FieldDefinition}
  alias Slipdock.Fields
  alias Slipdock.Swimlanes.Config

  attr :config, Config, required: true
  attr :prioritise, :map, required: true, doc: "from Slipdock.Prioritise.build/4"
  attr :can_write, :boolean, default: true
  attr :can_manage, :boolean, default: false
  attr :narrow, :boolean, default: false, doc: "stack each card instead of laying out columns"

  def prioritise_view(assigns) do
    p = assigns.prioritise

    assigns =
      assign(assigns,
        p: p,
        columns: 5 + length(p.inputs) + length(p.formulas),
        votes_pct: if(p.votes.budget > 0, do: div(p.votes.spent * 100, p.votes.budget), else: 0)
      )

    ~H"""
    <div id="prioritise-scroll" class="kanban-scroll h-full overflow-auto">
      <div class="flex flex-wrap items-center gap-x-6 gap-y-2 border-b border-base-300 bg-base-100/60 px-4 py-2 text-sm">
        <div class="flex items-center gap-3" title="Your voting budget on this board">
          <.icon name="hero-hand-thumb-up" class="size-4 text-base-content/50" />
          <span>
            <strong>{@p.votes.left}</strong>
            of {@p.votes.budget}
            {if @p.votes.budget == 1, do: "vote", else: "votes"} left
            <span class="text-base-content/50">· up to {@p.votes.max} per card</span>
          </span>
          <span class="h-1.5 w-24 overflow-hidden rounded-full bg-base-300" aria-hidden="true">
            <span class="block h-full bg-primary transition-all" style={"width: #{@votes_pct}%"}></span>
          </span>
        </div>
        <div :if={@p.formulas != []} class="flex flex-wrap items-center gap-2">
          <.icon name="hero-calculator" class="size-4 text-base-content/50" />
          <span
            :for={f <- @p.formulas}
            class="chip chip-line font-mono text-2xs"
            title={f.config["expression"]}
          >
            {f.name}
          </span>
          <span class="text-base-content/50">
            Ranked by <strong class="text-base-content">{@p.rank.label}</strong>{if @p.rank.auto?,
              do: ", highest first"}
          </span>
        </div>
        <div :if={@p.formulas == []} class="flex flex-wrap items-center gap-2 text-base-content/60">
          <.icon name="hero-calculator" class="size-4" />
          <span>No scoring model yet — ranked by votes.</span>
          <span :if={@can_manage} class="flex flex-wrap gap-1">
            <button
              :for={preset <- Fields.presets()}
              type="button"
              class="btn btn-xs"
              phx-click="install_preset"
              phx-value-key={preset.key}
              title={preset.blurb}
            >
              + {preset.name}
            </button>
          </span>
        </div>
      </div>

      <.view_empty
        :if={@p.entries == []}
        icon="hero-scale"
        variant="block"
        hidden={@p.hidden}
        config={@config}
      />

      <.prioritise_stack
        :if={@narrow and @p.entries != []}
        p={@p}
        config={@config}
        can_write={@can_write}
      />

      <table
        :if={!@narrow and @p.entries != []}
        id="prioritise-table"
        class="table table-sm table-pin-rows w-full text-sm"
      >
        <thead>
          <tr class="bg-base-100 text-xs uppercase tracking-wide text-base-content/60">
            <th class="w-10 text-right">#</th>
            <th>Card</th>
            <th class="w-32"><.sort_header sort="priority" label="Priority" config={@config} /></th>
            <th class="w-36"><.sort_header sort="votes" label="Votes" config={@config} /></th>
            <th :for={f <- @p.inputs} class="whitespace-nowrap">
              <.sort_header
                :if={FieldDefinition.numeric?(f)}
                sort={"f:#{f.id}"}
                label={f.name}
                config={@config}
              />
              <span :if={not FieldDefinition.numeric?(f)}>{f.name}</span>
            </th>
            <th :for={f <- @p.formulas} class="whitespace-nowrap text-right">
              <.sort_header sort={"f:#{f.id}"} label={f.name} config={@config} />
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={entry <- @p.entries}
            id={"prio-#{item_id(entry.card)}"}
            class={["hover:bg-base-200/40", entry.card.completed && "opacity-60"]}
          >
            <td class="text-right text-base-content/50">
              <span class={
                entry.rank <= 3 and not is_nil(entry.score) and "font-semibold text-primary"
              }>
                {entry.rank}
              </span>
            </td>
            <td class="max-w-md">
              <div class="flex min-w-0 items-center gap-2">
                <span
                  :if={entry.card.color}
                  class={["size-2 shrink-0 rounded-full", Slipdock.Palette.dot(entry.card.color)]}
                ></span>
                <span
                  role="link"
                  tabindex="0"
                  class={[
                    "cursor-pointer truncate font-medium hover:underline",
                    entry.card.completed && "text-base-content/50"
                  ]}
                  phx-click={open_item(entry.card)}
                  title={entry.card.title}
                >
                  {entry.card.title}
                </span>
                <.flag_icon
                  :for={flag <- entry.card.flags}
                  flag={flag}
                  card={entry.card}
                  class="size-3.5 shrink-0"
                />
                <span :if={entry.card.tags != []} class="hidden items-center gap-1 lg:flex">
                  <.tag_chip :for={tag <- entry.card.tags} tag={tag} size="xs" />
                </span>
              </div>
            </td>
            <td>
              <.priority_select
                :if={@can_write}
                id={"prio-priority-#{item_id(entry.card)}"}
                card_id={item_id(entry.card)}
                priority={entry.card.priority}
              />
              <.priority_badge :if={!@can_write} priority={entry.card.priority} />
            </td>
            <td>
              <.vote_control card={entry.card} mine={entry.mine} votes={@p.votes} />
            </td>
            <td :for={f <- @p.inputs} class="whitespace-nowrap">
              <.field_input
                field={f}
                item={entry.card}
                can_write={@can_write}
                id={"prio-field-#{item_id(entry.card)}-#{f.id}"}
                event="prio_field"
                params={[{"card_id", item_id(entry.card)}]}
                look={:bare}
              />
            </td>
            <td :for={f <- @p.formulas} class="text-right font-semibold">
              {Fields.format(f, Fields.value(entry.card, f)) || "—"}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :p, :map, required: true
  attr :config, Config, required: true
  attr :can_write, :boolean, required: true

  # Prioritising on a phone. The desktop table is rank, card, priority, votes
  # and then a column per scoring field — past four fields it is wider than a
  # phone twice over, and it was the *voting* that fell off the right-hand
  # edge, which is the one thing this view is for. Stacked, every card gets
  # its score and its vote buttons before anything else.
  defp prioritise_stack(assigns) do
    ~H"""
    <ul id="prioritise-table" class="divide-y divide-base-300/60">
      <li
        :for={entry <- @p.entries}
        id={"prio-#{item_id(entry.card)}"}
        class={["space-y-2 px-3 py-3", entry.card.completed && "opacity-60"]}
      >
        <div class="flex items-start gap-2">
          <span class={[
            "w-6 shrink-0 pt-0.5 text-right text-sm text-base-content/50",
            entry.rank <= 3 and not is_nil(entry.score) and "font-semibold text-primary"
          ]}>
            {entry.rank}
          </span>
          <span
            :if={entry.card.color}
            class={["mt-1.5 size-2 shrink-0 rounded-full", Slipdock.Palette.dot(entry.card.color)]}
          ></span>
          <span
            role="link"
            tabindex="0"
            class={[
              "min-w-0 flex-1 cursor-pointer text-sm font-medium",
              entry.card.completed && "text-base-content/50 line-through"
            ]}
            phx-click={open_item(entry.card)}
          >
            {entry.card.title}
          </span>
          <.flag_icon
            :for={flag <- entry.card.flags}
            flag={flag}
            card={entry.card}
            class="size-3.5 shrink-0"
          />
        </div>

        <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 pl-8">
          <span
            :for={f <- @p.formulas}
            class="chip chip-tint text-primary"
            title={f.name}
          >
            {f.name} {Fields.format(f, Fields.value(entry.card, f)) || "—"}
          </span>
          <.vote_control card={entry.card} mine={entry.mine} votes={@p.votes} />
        </div>

        <dl class="grid grid-cols-[5.5rem_minmax(0,1fr)] items-center gap-x-2 gap-y-1 pl-8">
          <dt class="text-2xs uppercase tracking-wide text-base-content/45">Priority</dt>
          <dd>
            <.priority_select
              :if={@can_write}
              id={"prio-priority-#{item_id(entry.card)}"}
              card_id={item_id(entry.card)}
              priority={entry.card.priority}
            />
            <.priority_badge :if={!@can_write} priority={entry.card.priority} />
          </dd>

          <div :for={f <- @p.inputs} class="contents">
            <dt class="truncate text-2xs uppercase tracking-wide text-base-content/45">{f.name}</dt>
            <dd>
              <.field_input
                field={f}
                item={entry.card}
                can_write={@can_write}
                id={"prio-field-#{item_id(entry.card)}-#{f.id}"}
                event="prio_field"
                params={[{"card_id", item_id(entry.card)}]}
                look={:bare}
              />
            </dd>
          </div>
        </dl>
      </li>
    </ul>
    """
  end

  attr :card, :any, required: true
  attr :mine, :integer, required: true
  attr :votes, :map, required: true

  # Everyone's votes, and −/+ for mine within the budget.
  defp vote_control(assigns) do
    assigns = assign(assigns, total: Card.vote_total(assigns.card))

    ~H"""
    <div class="flex items-center gap-1.5">
      <span class="w-6 text-right" title="Votes from everyone">{@total}</span>
      <span class="join">
        <button
          type="button"
          class="btn btn-ghost btn-xs join-item px-1.5"
          phx-click="prio_vote"
          phx-value-card_id={item_id(@card)}
          phx-value-count={@mine - 1}
          disabled={@mine <= 0}
          title="Take back one of my votes"
        >
          −
        </button>
        <span
          class={["join-item px-1.5 text-xs leading-6", @mine > 0 && "font-semibold text-primary"]}
          title="My votes on this card"
        >
          {@mine}
        </span>
        <button
          type="button"
          class="btn btn-ghost btn-xs join-item px-1.5"
          phx-click="prio_vote"
          phx-value-card_id={item_id(@card)}
          phx-value-count={@mine + 1}
          disabled={@mine >= @votes.max or @votes.left <= 0}
          title={
            cond do
              @mine >= @votes.max -> "At most #{@votes.max} per card"
              @votes.left <= 0 -> "No votes left"
              true -> "Add one of my votes"
            end
          }
        >
          +
        </button>
      </span>
    </div>
    """
  end
end

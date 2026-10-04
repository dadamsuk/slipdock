defmodule SlipdockWeb.SprintPlanComponents do
  @moduledoc """
  Planning sprints: choosing the boards and lists a sprint board plans from
  (`sources_fields/1`, used in board settings, the new-board form and the
  planning view itself), and the planning table those lists make
  (`plan_table/1`), from `Slipdock.Sprints.plan/3`.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents, only: [priority_badge: 1]

  alias Slipdock.{Fields, Palette, Sprints, TimeTracking}

  ## Sources

  @doc """
  The sources as the form shows them: board id to the list ids picked on it
  (`[]` for every open list), from what is stored on `board`.
  """
  def chosen(%{sprint_sources: sources}) do
    sources
    |> List.wrap()
    |> Map.new(&{&1["board_id"], List.wrap(&1["column_ids"])})
  end

  def chosen(_), do: %{}

  @doc """
  Reads `sources_fields/1`'s params back into what
  `Slipdock.Sprints.put_sources/3` takes, in the order `choices` lists the
  boards. Anything not among `choices` is ignored.
  """
  def parse_sources(params, choices) when is_map(params) do
    Enum.flat_map(choices, fn board ->
      case Map.get(params, to_string(board.id)) do
        %{"on" => "true"} = source ->
          ids = Map.new(board.columns, &{to_string(&1.id), &1.id})

          lists =
            source
            |> Map.get("lists", [])
            |> List.wrap()
            |> Enum.flat_map(&List.wrap(ids[&1]))

          [{board.id, lists}]

        _ ->
          []
      end
    end)
  end

  def parse_sources(_, _), do: []

  @doc "`parse_sources/2`'s result as `chosen/1` gives it, for redrawing a form."
  def chosen_from(parsed), do: Map.new(parsed)

  attr :choices, :list, required: true, doc: "from Slipdock.Sprints.source_choices/2"
  attr :chosen, :map, required: true, doc: "board id => list ids, see chosen/1"
  attr :name, :string, default: "sources"

  @doc """
  A tick per board to plan from and, under a ticked board, a tick per list.
  No list ticked means every list that is not done or dropped.
  """
  def sources_fields(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <p :if={@choices == []} class="text-sm text-base-content/60">
        There is no other board you can write to.
      </p>
      <div
        :for={board <- @choices}
        id={"sprint-source-#{board.id}"}
        class="rounded-lg px-2 py-1.5 ring-1 ring-base-content/10"
      >
        <label class="flex cursor-pointer items-center gap-2 text-sm">
          <input
            type="checkbox"
            name={"#{@name}[#{board.id}][on]"}
            value="true"
            checked={Map.has_key?(@chosen, board.id)}
            class="checkbox checkbox-sm"
          />
          <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(board.color)]}></span>
          <span class="min-w-0 flex-1 truncate font-medium">{board.name}</span>
        </label>
        <div :if={Map.has_key?(@chosen, board.id)} class="mt-1.5 flex flex-wrap gap-1.5 pl-6">
          <label
            :for={column <- board.columns}
            class="flex cursor-pointer items-center gap-1 rounded-md bg-base-200/60 px-1.5 py-0.5 text-xs"
          >
            <input
              type="checkbox"
              name={"#{@name}[#{board.id}][lists][]"}
              value={column.id}
              checked={column.id in Map.get(@chosen, board.id, [])}
              class="checkbox checkbox-xs"
            />
            {column.name}
          </label>
          <span
            :if={Map.get(@chosen, board.id) == []}
            class="self-center text-2xs text-base-content/50"
          >
            none ticked: every open list
          </span>
        </div>
      </div>
    </div>
    """
  end

  ## The planning table

  attr :plan, :map, required: true, doc: "from Slipdock.Sprints.plan/3"
  attr :selected, :map, required: true, doc: "card id => %{estimate:, ancestors:}"
  attr :expanded, :map, required: true, doc: "card id => its subcards' entries"
  attr :target, :any, required: true

  @doc """
  Every source list at once, grouped by board: a tick per card, and what
  helps choose — priority, the board's formula scores, votes, the estimate
  and how far its subcards have got. A card with subcards opens in place,
  the way the outline does.
  """
  def plan_table(assigns) do
    ~H"""
    <div class="space-y-5">
      <p :if={@plan.boards == []} class="text-sm text-base-content/60">
        None of the boards this sprint board plans from can be reached any more.
      </p>
      <section :for={group <- @plan.boards} id={"plan-board-#{group.board.id}"} class="space-y-2">
        <h3 class="flex items-center gap-2 text-sm font-semibold">
          <span class={["size-2.5 rounded-full", Palette.dot(group.board.color)]}></span>
          {group.board.name}
        </h3>
        <p :if={group.lists == []} class="text-xs text-base-content/50">No lists chosen.</p>
        <div :for={list <- group.lists} id={"plan-list-#{list.id}"}>
          <div class="mb-1 flex items-center gap-1.5 px-1 text-xs font-semibold">
            <span :if={list.color} class={["size-2 rounded-full", Palette.dot(list.color)]}></span>
            <span class="truncate">{list.name}</span>
            <span class="font-mono text-2xs text-base-content/50">{length(list.cards)}</span>
            <button
              :if={Enum.any?(list.cards, & &1.pickable)}
              phx-target={@target}
              type="button"
              phx-click="sprint_toggle_list"
              phx-value-id={list.id}
              class="link link-hover ml-auto text-2xs font-normal text-base-content/60"
            >
              {if Enum.all?(
                    Enum.filter(list.cards, & &1.pickable),
                    &Map.has_key?(@selected, &1.id)
                  ),
                  do: "untick all",
                  else: "tick all"}
            </button>
          </div>
          <p :if={list.cards == []} class="px-1 text-xs text-base-content/40">Nothing open.</p>
          <div
            :if={list.cards != []}
            class="overflow-x-auto rounded-xl ring-1 ring-base-content/10"
          >
            <table class="w-full text-sm">
              <thead class="text-2xs uppercase tracking-wide text-base-content/50">
                <tr class="border-b border-base-300/60">
                  <th class="w-8"></th>
                  <th class="px-2 py-1 text-left font-semibold">Card</th>
                  <th class="px-2 py-1 text-left font-semibold">Priority</th>
                  <th
                    :for={f <- group.formulas}
                    class="px-2 py-1 text-right font-semibold"
                    title={f.name}
                  >
                    {f.name}
                  </th>
                  <th class="px-2 py-1 text-right font-semibold">Votes</th>
                  <th class="px-2 py-1 text-right font-semibold">Estimate</th>
                  <th class="px-2 py-1 text-right font-semibold">Subcards</th>
                  <th class="px-2 py-1 text-right font-semibold">Due</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300/60">
                <.plan_rows
                  cards={list.cards}
                  formulas={group.formulas}
                  selected={@selected}
                  expanded={@expanded}
                  target={@target}
                  level={0}
                />
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr :cards, :list, required: true
  attr :formulas, :list, required: true
  attr :selected, :map, required: true
  attr :expanded, :map, required: true
  attr :target, :any, required: true
  attr :level, :integer, required: true

  defp plan_rows(assigns) do
    ~H"""
    <%= for card <- @cards do %>
      <% inside = Enum.any?(card.ancestors, &Map.has_key?(@selected, &1)) %>
      <tr id={"plan-card-#{card.id}"} class={["hover:bg-base-200/40", inside && "opacity-60"]}>
        <td class="px-2 py-1.5 text-center">
          <input
            :if={card.pickable}
            phx-target={@target}
            type="checkbox"
            id={"sprint-pick-#{card.id}"}
            class="checkbox checkbox-sm"
            checked={Map.has_key?(@selected, card.id)}
            phx-click="sprint_toggle"
            phx-value-id={card.id}
          />
        </td>
        <td class="max-w-0 px-2 py-1.5">
          <div class="flex min-w-0 items-center gap-1" style={"padding-left: #{@level * 1.25}rem"}>
            <button
              :if={card.sub_board_id}
              phx-target={@target}
              type="button"
              phx-click="plan_expand"
              phx-value-id={card.id}
              class="btn btn-ghost btn-xs btn-square shrink-0"
              title={if Map.has_key?(@expanded, card.id), do: "Hide subcards", else: "Show subcards"}
            >
              <.icon
                name={
                  if Map.has_key?(@expanded, card.id),
                    do: "hero-chevron-down",
                    else: "hero-chevron-right"
                }
                class="size-3.5"
              />
            </button>
            <span :if={is_nil(card.sub_board_id)} class="w-6 shrink-0"></span>
            <label for={"sprint-pick-#{card.id}"} class="min-w-0 flex-1 cursor-pointer truncate">
              {card.title}
            </label>
          </div>
        </td>
        <td class="px-2 py-1.5">
          <.priority_badge :if={card.priority not in [nil, "none"]} priority={card.priority} />
        </td>
        <td
          :for={{field, value} <- card.scores}
          class="px-2 py-1.5 text-right font-mono text-xs tabular-nums"
        >
          {Fields.format(field, value)}
        </td>
        <td
          :for={_ <- List.duplicate(nil, max(length(@formulas) - length(card.scores), 0))}
          class="px-2 py-1.5"
        >
        </td>
        <td class="px-2 py-1.5 text-right font-mono text-xs tabular-nums">
          {if card.votes > 0, do: card.votes}
        </td>
        <td
          class="px-2 py-1.5 text-right font-mono text-xs tabular-nums"
          title={card.estimate_derived && "Added up from its open subcards"}
        >
          <span :if={card.estimate_derived && card.estimate} class="text-base-content/50">Σ</span>
          {TimeTracking.format(card.estimate, card.unit)}
        </td>
        <td class="px-2 py-1.5 text-right font-mono text-xs tabular-nums text-base-content/60">
          {if card.total > 0 and card.children > 0, do: "#{card.done}/#{card.total}"}
        </td>
        <td class="whitespace-nowrap px-2 py-1.5 text-right text-xs text-base-content/60">
          {card.due_date && Calendar.strftime(card.due_date, "%-d %b")}
        </td>
      </tr>
      <.plan_rows
        :if={Map.has_key?(@expanded, card.id)}
        cards={@expanded[card.id]}
        formulas={@formulas}
        selected={@selected}
        expanded={@expanded}
        target={@target}
        level={@level + 1}
      />
    <% end %>
    """
  end

  attr :committed, :map, required: true
  attr :selected, :map, required: true
  attr :days, :integer, default: nil

  @doc """
  What the sprint holds already and what the ticks would add: cards and
  estimated hours. A card inside a ticked card is not counted twice.
  """
  def plan_totals(assigns) do
    ticked = Sprints.selection_totals(assigns.selected)
    assigns = assign(assigns, ticked: ticked)

    ~H"""
    <div id="sprint-plan-totals" class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
      <span>
        <span class="font-semibold">
          {@ticked.cards} card{if @ticked.cards == 1, do: "", else: "s"} ticked
        </span>
        <span :if={@ticked.estimate > 0} class="font-mono text-xs">
          · {TimeTracking.format(@ticked.estimate, "hours")}
        </span>
      </span>
      <span class="text-base-content/60">
        in the sprint already: {@committed.open} open
        <span :if={@committed.estimate > 0} class="font-mono text-xs">
          · {TimeTracking.format(@committed.estimate, "hours")}
        </span>
      </span>
      <span :if={@ticked.cards > 0} class="font-medium">
        total {@committed.open + @ticked.cards} cards<span :if={
          @committed.estimate + @ticked.estimate > 0
        }>, {TimeTracking.format(@committed.estimate + @ticked.estimate, "hours")}</span>
        <span :if={@days} class="text-base-content/60">over {@days} days</span>
      </span>
    </div>
    """
  end
end

defmodule SlipdockWeb.PrioritiseComponents do
  @moduledoc """
  The prioritise view: a ranked table where priority, votes and every
  scoring field are edited in place (see `Slipdock.Prioritise`).
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  alias Slipdock.Boards.{Card, FieldDefinition}
  alias Slipdock.Fields
  alias Slipdock.Swimlanes.Config

  attr :board, :any, required: true
  attr :config, Config, required: true
  attr :prioritise, :map, required: true, doc: "from Slipdock.Prioritise.build/4"
  attr :can_write, :boolean, default: true
  attr :can_manage, :boolean, default: false
  attr :current_user, :any, default: nil
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

      <div
        :if={@p.entries == []}
        class="flex h-64 flex-col items-center justify-center gap-2 p-8 text-center text-base-content/60"
      >
        <.icon name="hero-scale" class="size-10 opacity-40" />
        <p :if={@p.hidden > 0}>No cards match the current filters.</p>
        <p :if={@p.hidden == 0}>This board has no cards yet.</p>
        <button
          :if={Config.filtering?(@config)}
          type="button"
          class="btn btn-sm"
          phx-click="swim_clear_filters"
        >
          Clear filters
        </button>
      </div>

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
            <td class="text-right font-mono text-base-content/50">
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
                <.flag_icon :for={flag <- entry.card.flags} flag={flag} class="size-3.5 shrink-0" />
                <span :if={entry.card.tags != []} class="hidden items-center gap-1 lg:flex">
                  <.tag_chip :for={tag <- entry.card.tags} tag={tag} size="xs" />
                </span>
              </div>
            </td>
            <td>
              <form
                :if={@can_write}
                phx-change="table_update"
                phx-submit="table_update"
                id={"prio-priority-#{item_id(entry.card)}"}
              >
                <input type="hidden" name="card_id" value={item_id(entry.card)} />
                <input type="hidden" name="field" value="priority" />
                <select name="value" class="select select-ghost select-xs w-28">
                  <option
                    :for={{label, value} <- priority_options()}
                    value={value}
                    selected={value == entry.card.priority}
                  >
                    {label}
                  </option>
                </select>
              </form>
              <.priority_badge :if={!@can_write} priority={entry.card.priority} />
            </td>
            <td>
              <.vote_control card={entry.card} mine={entry.mine} votes={@p.votes} />
            </td>
            <td :for={f <- @p.inputs} class="whitespace-nowrap">
              <.field_editor field={f} card={entry.card} can_write={@can_write} />
            </td>
            <td :for={f <- @p.formulas} class="text-right font-mono font-semibold">
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
            "w-6 shrink-0 pt-0.5 text-right font-mono text-sm text-base-content/50",
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
          <.flag_icon :for={flag <- entry.card.flags} flag={flag} class="size-3.5 shrink-0" />
        </div>

        <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 pl-8">
          <span
            :for={f <- @p.formulas}
            class="chip chip-tint font-mono text-primary"
            title={f.name}
          >
            {f.name} {Fields.format(f, Fields.value(entry.card, f)) || "—"}
          </span>
          <.vote_control card={entry.card} mine={entry.mine} votes={@p.votes} />
        </div>

        <dl class="grid grid-cols-[5.5rem_minmax(0,1fr)] items-center gap-x-2 gap-y-1 pl-8">
          <dt class="text-2xs uppercase tracking-wide text-base-content/45">Priority</dt>
          <dd>
            <form
              :if={@can_write}
              phx-change="table_update"
              phx-submit="table_update"
              id={"prio-priority-#{item_id(entry.card)}"}
            >
              <input type="hidden" name="card_id" value={item_id(entry.card)} />
              <input type="hidden" name="field" value="priority" />
              <select name="value" class="select select-ghost select-xs w-28">
                <option
                  :for={{label, value} <- priority_options()}
                  value={value}
                  selected={value == entry.card.priority}
                >
                  {label}
                </option>
              </select>
            </form>
            <.priority_badge :if={!@can_write} priority={entry.card.priority} />
          </dd>

          <div :for={f <- @p.inputs} class="contents">
            <dt class="truncate text-2xs uppercase tracking-wide text-base-content/45">{f.name}</dt>
            <dd><.field_editor field={f} card={entry.card} can_write={@can_write} /></dd>
          </div>
        </dl>
      </li>
    </ul>
    """
  end

  attr :sort, :string, required: true
  attr :label, :string, required: true
  attr :config, Config, required: true

  defp sort_header(assigns) do
    ~H"""
    <button
      type="button"
      class="flex items-center gap-1 uppercase hover:text-base-content"
      phx-click="table_sort"
      phx-value-sort={@sort}
      title={"Sort by #{@label}"}
    >
      {@label}
      <.icon
        :if={@config.sort == @sort}
        name={if @config.dir == "asc", do: "hero-arrow-up", else: "hero-arrow-down"}
        class="size-3"
      />
    </button>
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
      <span class="w-6 text-right font-mono" title="Votes from everyone">{@total}</span>
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

  attr :field, FieldDefinition, required: true
  attr :card, :any, required: true
  attr :can_write, :boolean, required: true

  defp field_editor(%{can_write: false} = assigns) do
    ~H"""
    <span>{Fields.format(@field, Fields.value(@card, @field)) || "—"}</span>
    """
  end

  defp field_editor(%{field: %{kind: "rating"}} = assigns) do
    assigns = assign(assigns, value: Fields.value(assigns.card, assigns.field))

    ~H"""
    <div class="flex items-center gap-0.5" id={"prio-field-#{item_id(@card)}-#{@field.id}"}>
      <button
        :for={n <- 1..FieldDefinition.rating_max(@field)//1}
        type="button"
        class={[
          "text-sm leading-none transition hover:scale-110",
          if(is_number(@value) and n <= @value, do: "text-amber-500", else: "text-base-content/25")
        ]}
        phx-click="prio_field"
        phx-value-card_id={item_id(@card)}
        phx-value-field_id={@field.id}
        value={n}
        title={"#{n} of #{FieldDefinition.rating_max(@field)}"}
      >
        ★
      </button>
      <button
        :if={is_number(@value)}
        type="button"
        class="btn btn-ghost btn-xs btn-square"
        phx-click="prio_field"
        phx-value-card_id={item_id(@card)}
        phx-value-field_id={@field.id}
        value=""
        title="Clear"
      >
        <.icon name="hero-x-mark" class="size-3" />
      </button>
    </div>
    """
  end

  defp field_editor(%{field: %{kind: "select"}} = assigns) do
    assigns = assign(assigns, value: Fields.value(assigns.card, assigns.field))

    ~H"""
    <form
      phx-change="prio_field"
      phx-submit="prio_field"
      id={"prio-field-#{item_id(@card)}-#{@field.id}"}
    >
      <input type="hidden" name="card_id" value={item_id(@card)} />
      <input type="hidden" name="field_id" value={@field.id} />
      <select name="value" class="select select-ghost select-xs w-28">
        <option value="" selected={is_nil(@value)}>—</option>
        <option :for={o <- @field.options} value={o["key"]} selected={o["key"] == @value}>
          {o["label"]}
        </option>
      </select>
    </form>
    """
  end

  defp field_editor(assigns) do
    value = Fields.value(assigns.card, assigns.field)
    config = assigns.field.config || %{}

    assigns =
      assign(assigns,
        value: value,
        config: config,
        input_type:
          case assigns.field.kind do
            "number" -> "number"
            "date" -> "date"
            _ -> "text"
          end
      )

    ~H"""
    <form
      phx-change="prio_field"
      phx-submit="prio_field"
      id={"prio-field-#{item_id(@card)}-#{@field.id}"}
      class="flex items-center gap-1"
    >
      <input type="hidden" name="card_id" value={item_id(@card)} />
      <input type="hidden" name="field_id" value={@field.id} />
      <input
        type={@input_type}
        name="value"
        value={input_value(@input_type, @value)}
        step={@input_type == "number" && "any"}
        min={@config["min"]}
        max={@config["max"]}
        phx-debounce="blur"
        class={["input input-ghost input-xs", if(@input_type == "text", do: "w-36", else: "w-24")]}
        placeholder="—"
      />
      <span :if={@config["unit"] && @input_type == "number"} class="text-xs text-base-content/50">
        {@config["unit"]}
      </span>
    </form>
    """
  end

  defp input_value("date", %Date{} = d), do: Date.to_iso8601(d)
  defp input_value(_, n) when is_float(n), do: if(n == trunc(n), do: trunc(n), else: n)
  defp input_value(_, v), do: v
end

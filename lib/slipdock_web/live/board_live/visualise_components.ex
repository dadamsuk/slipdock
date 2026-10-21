defmodule SlipdockWeb.BoardLive.VisualiseComponents do
  @moduledoc """
  The sections of a board's Visualise page (`SlipdockWeb.BoardLive.Visualise`),
  and the small pieces they share: a section card, a tile, a chip, and the
  way a duration reads. App UI tokens only (base, primary, success, warning,
  error), so every piece follows the theme, light or dark.
  """
  use SlipdockWeb, :html

  @doc """
  Seconds as the page writes them: 47s, 10m 47s, 1h 23m, 12.8 days. A dash
  when there is nothing to say.
  """
  def duration(nil), do: "–"
  def duration(s) when s < 60, do: "#{round(s)}s"

  def duration(s) when s < 3600 do
    s = round(s)
    "#{div(s, 60)}m #{rem(s, 60)}s"
  end

  def duration(s) when s < 86_400 do
    s = round(s)
    "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
  end

  def duration(s), do: "#{:erlang.float_to_binary(s / 86_400, decimals: 1)} days"

  attr :days, :integer, required: true

  @doc "The 7 / 30 / 90 day switch: real buttons, the chosen one pressed."
  def window_switch(assigns) do
    assigns = assign(assigns, windows: Slipdock.Flow.windows())

    ~H"""
    <div
      id="window-switch"
      role="group"
      aria-label="Trend window"
      class="inline-flex rounded-field bg-base-100 p-0.5 shadow-sm ring-1 ring-base-content/10"
    >
      <button
        :for={d <- @windows}
        id={"window-#{d}"}
        type="button"
        phx-click="window"
        phx-value-days={d}
        aria-pressed={to_string(d == @days)}
        class={[
          "rounded-field px-3 py-1 text-xs font-medium tabular-nums focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
          if(d == @days,
            do: "bg-primary/10 text-primary",
            else: "text-base-content/70 hover:bg-base-200"
          )
        ]}
      >
        {d} days
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :note, :string, default: nil, doc: "the muted line beside the title: its window"
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :aside, doc: "the right of the heading"

  @doc "One section of the page: a card on the page's recessed ground."
  def section(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={"#{@id}-title"}
      class={["rounded-box bg-base-100 p-4 shadow-sm sm:p-5", @class]}
    >
      <div class="mb-3 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <div class="flex min-w-0 flex-wrap items-baseline gap-x-2">
          <h2 id={"#{@id}-title"} class="text-base font-semibold">{@title}</h2>
          <span :if={@note} class="text-xs text-base-content/60">{@note}</span>
        </div>
        {render_slot(@aside)}
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :tone, :atom, default: :neutral, values: [:neutral, :primary, :success, :warning, :error]
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  @doc "A soft tinted chip; the words carry the state, the colour only helps."
  def chip(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-2xs font-medium tabular-nums",
        tone_class(@tone),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp tone_class(:primary), do: "bg-primary/10 text-primary"
  defp tone_class(:success), do: "bg-success/15 text-success"
  defp tone_class(:warning), do: "bg-warning/15 text-warning"
  defp tone_class(:error), do: "bg-error/15 text-error"
  defp tone_class(:neutral), do: "bg-base-200 text-base-content/70"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :detail, :string, default: nil
  slot :chip

  @doc "A figure with its label above and its detail beneath."
  def tile(assigns) do
    ~H"""
    <div id={@id} class="min-w-0 rounded-box bg-base-200/60 p-3">
      <div class="text-2xs font-medium uppercase tracking-wide text-base-content/60">{@label}</div>
      <div class="mt-1 flex flex-wrap items-center gap-2">
        <span class="text-2xl font-semibold tabular-nums" data-value>{@value}</span>
        {render_slot(@chip)}
      </div>
      <div :if={@detail} class="mt-0.5 truncate text-xs text-base-content/60 tabular-nums">
        {@detail}
      </div>
    </div>
    """
  end

  ## Pulse ---------------------------------------------------------------------

  attr :pulse, :map, required: true
  attr :dora, :map, default: nil, doc: "the DORA report, nil while delivery metrics are off"
  attr :doing, :any, default: nil, doc: "the board's doing list, for its WIP limit"
  attr :last_answer, :integer, default: nil

  @doc "The pulse tiles: Pulse's own 7 days, with idea to production from DORA."
  def pulse_section(assigns) do
    p = assigns.pulse
    t = p.time_to_done
    limit = assigns.doing && assigns.doing.wip_limit
    idea = assigns.dora && assigns.dora.idea_to_production

    assigns =
      assign(assigns,
        t: t,
        limit: limit,
        at_limit: is_integer(limit) and p.in_progress >= limit,
        idea: idea
      )

    ~H"""
    <.section id="pulse" title="Pulse" note="Last 7 days">
      <div class="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        <.tile
          id="tile-throughput"
          label="Throughput"
          value={to_string(@pulse.done_7d)}
          detail={"done in 7 days · #{@pulse.done_today} today"}
        />
        <.tile
          id="tile-cycle"
          label="Cycle time P50"
          value={duration(@t.p50)}
          detail={"P85 #{duration(@t.p85)} · #{@t.cards} #{plural(@t.cards, "card")} (90 days)"}
        />
        <.tile
          :if={@idea}
          id="tile-idea"
          label="Idea to production P50"
          value={duration(@idea.p50)}
          detail={"P85 #{duration(@idea.p85)} · #{@idea.cards} #{plural(@idea.cards, "card")} (#{@dora.days} days)"}
        />
        <.tile
          id="tile-wip"
          label="Work in progress"
          value={
            if @limit, do: "#{@pulse.in_progress} / #{@limit}", else: to_string(@pulse.in_progress)
          }
          detail={if @limit, do: "against the WIP limit", else: "no WIP limit set"}
        >
          <:chip>
            <.chip :if={@at_limit} tone={:warning} id="wip-at-limit">At limit</.chip>
          </:chip>
        </.tile>
        <.tile
          id="tile-waiting"
          label="Waiting on people"
          value={to_string(@pulse.waiting)}
          detail={
            if @last_answer,
              do: "open · last answered in #{duration(@last_answer)}",
              else: "open · none answered yet"
          }
        />
        <.tile
          id="tile-moves"
          label="Moves in 24h"
          value={to_string(@pulse.moves_24h.total)}
          detail={"#{@pulse.moves_24h.forward} forward · #{@pulse.moves_24h.back} back"}
        />
      </div>
    </.section>
    """
  end

  ## Flow through the board ----------------------------------------------------

  attr :lists, :list,
    required: true,
    doc: "each list in board order: Pulse's figures plus `count`, `archived_7d` and `wip_limit`"

  @doc """
  One block per list in board order, with arrows between the lists in the
  flow; lists with no category sit apart at the end, dashed.
  """
  def flow_section(assigns) do
    {flow, outside} = Enum.split_with(assigns.lists, & &1.category)
    top = flow |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, flow: flow, outside: outside, top: top)

    ~H"""
    <.section id="flow" title="Flow through the board" note="Now, with in and out over 7 days">
      <div class="flex flex-wrap items-stretch gap-2">
        <%= for {list, i} <- Enum.with_index(@flow) do %>
          <div
            :if={i > 0}
            class="hidden items-center text-base-content/40 sm:flex"
            aria-hidden="true"
          >
            <.icon name="hero-arrow-right" class="size-4" />
          </div>
          <.flow_block list={list} top={@top} />
        <% end %>
        <.flow_block :for={list <- @outside} list={list} top={@top} outside />
      </div>
    </.section>
    """
  end

  attr :list, :map, required: true
  attr :top, :integer, required: true
  attr :outside, :boolean, default: false

  defp flow_block(assigns) do
    l = assigns.list
    limit = l.category == "doing" && l.wip_limit
    at_limit = is_integer(limit) and l.count >= limit

    fill =
      cond do
        is_integer(limit) and limit > 0 -> min(l.count / limit, 1)
        assigns.top > 0 -> l.count / assigns.top
        true -> 0
      end

    assigns =
      assign(assigns, limit: limit, at_limit: at_limit, fill: round(fill * 100), l: l)

    ~H"""
    <div
      id={"flow-list-#{@l.id}"}
      data-category={@l.category || "none"}
      class={[
        "flex min-w-36 flex-1 basis-36 flex-col gap-1.5 rounded-box p-3",
        @outside && "border border-dashed border-base-content/25 text-base-content/70",
        !@outside && @l.category == "doing" && "bg-primary/10 ring-1 ring-primary/20",
        !@outside && @l.category == "done" && "bg-success/10 ring-1 ring-success/20",
        !@outside && @l.category not in ["doing", "done"] && "bg-base-300/60"
      ]}
    >
      <div class="flex items-center justify-between gap-2">
        <span class="truncate text-sm font-semibold">{@l.name}</span>
        <.chip
          id={"flow-count-#{@l.id}"}
          tone={
            cond do
              @at_limit -> :warning
              @l.category == "doing" -> :primary
              @l.category == "done" -> :success
              true -> :neutral
            end
          }
          title={if @at_limit, do: "At the WIP limit"}
        >
          {if @limit, do: "#{@l.count} / #{@limit}", else: @l.count}
        </.chip>
      </div>
      <div :if={@outside} class="text-2xs text-base-content/60">Outside the flow</div>
      <div :if={!@outside} class="text-xs tabular-nums text-base-content/70">
        In {@l.in_7d} · <span :if={@l.category == "done"}>Archived {@l.archived_7d}</span>
        <span :if={@l.category != "done"}>Out {@l.out_7d}</span>
      </div>
      <div class="h-1 overflow-hidden rounded-full bg-base-content/10" aria-hidden="true">
        <div
          class={[
            "h-full rounded-full",
            cond do
              @at_limit -> "bg-warning"
              @l.category == "doing" -> "bg-primary"
              @l.category == "done" -> "bg-success"
              true -> "bg-base-content/40"
            end
          ]}
          style={"width: #{@fill}%"}
        >
        </div>
      </div>
      <div :if={!@outside} class="text-2xs text-base-content/60">
        Usual stay {if @l.usual_stay, do: duration(@l.usual_stay), else: "not known yet"}
      </div>
    </div>
    """
  end

  ## Aging work in progress ---------------------------------------------------

  attr :board, :any, required: true
  attr :aging, :list, required: true, doc: "open cards in doing and ready lists, oldest first"
  attr :outside, :list, default: [], doc: "`{list name, open cards}` for uncategorised lists"

  @doc """
  Each open card in the doing and ready lists, oldest first, its age
  against its list's usual stay. Past it, the bar turns warning and says so
  (`Slipdock.CardState`'s `stuck`: the same rule as the stuck filter).
  """
  def aging_section(assigns) do
    ~H"""
    <.section id="aging" title="Aging work in progress" note="In doing and ready lists">
      <p :if={@aging == []} id="aging-empty" class="text-sm text-base-content/60">
        Nothing in progress.
      </p>
      <ul :if={@aging != []} class="divide-y divide-base-content/5">
        <li
          :for={a <- @aging}
          id={"aging-#{a.card.id}"}
          data-stuck={to_string(a.stuck)}
          class="flex flex-col gap-1.5 py-2.5 first:pt-0 last:pb-0"
        >
          <div class="flex min-w-0 flex-wrap items-center gap-1.5">
            <.link
              navigate={~p"/boards/#{@board}/cards/#{a.card.id}"}
              class="min-w-0 flex-1 basis-40 truncate text-sm font-medium hover:underline"
            >
              {a.card.title}
            </.link>
            <.chip class="font-mono">#{a.card.id}</.chip>
            <.chip>{a.list}</.chip>
            <span
              :for={tag <- a.card.tags}
              class={[
                "inline-flex items-center rounded-full px-2 py-0.5 text-2xs font-medium",
                Slipdock.Palette.chip(tag.color)
              ]}
            >
              {tag.name}
            </span>
            <.chip :if={a.driver == "agent"} tone={:primary}>Agent</.chip>
            <.chip :if={a.driver == "human"}>Human</.chip>
            <.chip :if={a.stuck} tone={:warning}>Past usual stay</.chip>
          </div>
          <div class="flex items-center gap-2">
            <div
              class="h-1.5 flex-1 overflow-hidden rounded-full bg-base-content/10"
              role="img"
              aria-label={aging_label(a)}
            >
              <div
                class={["h-full rounded-full", if(a.stuck, do: "bg-warning", else: "bg-primary")]}
                style={"width: #{aging_fill(a)}%"}
              >
              </div>
            </div>
            <span class="shrink-0 text-2xs tabular-nums text-base-content/60">
              {duration(a.age)} · {if a.usual,
                do: "usual #{duration(a.usual)}",
                else: "no usual stay yet"}
            </span>
          </div>
        </li>
      </ul>
      <p
        :if={@outside != []}
        id="aging-outside"
        class="mt-3 rounded-box border border-dashed border-base-content/20 px-3 py-2 text-xs text-base-content/60"
      >
        Not aged, as outside the flow: {Enum.map_join(@outside, ", ", fn {name, n} ->
          "#{n} in #{name}"
        end)}.
      </p>
    </.section>
    """
  end

  defp aging_fill(%{usual: usual, age: age})
       when is_integer(usual) and usual > 0 and is_integer(age),
       do: round(min(age / usual, 1) * 100)

  defp aging_fill(_), do: 0

  defp aging_label(a) do
    "#{duration(a.age)} in #{a.list}" <>
      cond do
        a.stuck -> ", past its usual stay of #{duration(a.usual)}"
        a.usual -> ", usual stay #{duration(a.usual)}"
        true -> ""
      end
  end

  ## Work mix -------------------------------------------------------------------

  attr :mix, :map, required: true, doc: "`%{total, untagged, tags: [%{tag, count}]}`"
  attr :days, :integer, required: true

  @doc "Tag counts on the done cards, one bar scale for all of them."
  def mix_section(assigns) do
    top = assigns.mix.tags |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, top: max(top, 1))

    ~H"""
    <.section
      id="mix"
      title="Work mix"
      note={"Tags on done cards, archived ones from the last #{@days} days"}
    >
      <p :if={@mix.tags == []} id="mix-empty" class="text-sm text-base-content/60">
        This board has no tags yet.
      </p>
      <ul :if={@mix.tags != []} class="space-y-2">
        <li
          :for={t <- @mix.tags}
          id={"mix-tag-#{t.tag.id}"}
          class="grid grid-cols-[minmax(0,10rem)_1fr_2.5rem] items-center gap-2 text-sm"
        >
          <span class="flex min-w-0 items-center gap-1.5">
            <span class={["size-2 shrink-0 rounded-full", Slipdock.Palette.dot(t.tag.color)]}></span>
            <span class="truncate">{t.tag.name}</span>
          </span>
          <span class="h-1.5 overflow-hidden rounded-full bg-base-content/10" aria-hidden="true">
            <span
              class="block h-full rounded-full bg-primary/60"
              style={"width: #{round(t.count / @top * 100)}%"}
            ></span>
          </span>
          <span class="text-right text-xs tabular-nums" data-count>{t.count}</span>
        </li>
      </ul>
      <p :if={@mix.untagged > 0} id="mix-untagged" class="mt-3 text-xs text-base-content/60">
        {@mix.untagged} of {@mix.total} done cards carry no tag, so the mix is a floor, not a full picture.
      </p>
    </.section>
    """
  end

  @doc false
  def plural(1, word), do: word
  def plural(_, word), do: word <> "s"
end

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
      <div :if={@detail} class="mt-0.5 text-xs text-base-content/60 tabular-nums">
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
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 md:grid-cols-3 xl:grid-cols-6">
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

  ## Agentic runners ----------------------------------------------------------

  attr :board, :any, required: true
  attr :stats, :map, required: true, doc: "from Slipdock.RunnerStats.for_board/2"

  @doc "A card per runner taking work from the board, then its recent jobs."
  def runners_section(assigns) do
    jobs = assigns.stats.recent_jobs
    longest = jobs |> Enum.map(&(&1.duration || 0)) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, jobs: jobs, longest: max(longest, 1))

    ~H"""
    <.section id="runners" title="Agentic runners" note={"Last #{@stats.days} days"}>
      <p :if={@stats.runners == []} id="runners-empty" class="text-sm text-base-content/60">
        No runners take work from this board. <.link
          navigate={~p"/boards/#{@board}/automations"}
          class="link"
        >Set one up in Automations</.link>.
      </p>
      <div :if={@stats.runners != []} class="flex flex-wrap items-start gap-4">
        <.runner_card :for={r <- @stats.runners} runner={r} />
        <div class="min-w-0 flex-[2_1_28rem]">
          <h3 class="mb-2 text-sm font-semibold">Recent jobs</h3>
          <p :if={@jobs == []} id="jobs-empty" class="text-sm text-base-content/60">No jobs yet.</p>
          <div :if={@jobs != []} class="overflow-x-auto">
            <table id="recent-jobs" class="w-full min-w-[32rem] text-sm">
              <thead class="text-left text-2xs uppercase tracking-wide text-base-content/60">
                <tr>
                  <th class="py-1 pr-2 font-medium">Job</th>
                  <th class="py-1 pr-2 font-medium">Card</th>
                  <th class="py-1 pr-2 font-medium">Outcome</th>
                  <th class="py-1 font-medium">Duration</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-content/5">
                <tr :for={j <- @jobs} id={"job-#{j.job_id}"}>
                  <td class="py-1.5 pr-2 font-mono text-xs">#{j.job_id}</td>
                  <td class="max-w-56 py-1.5 pr-2">
                    <.link
                      navigate={~p"/boards/#{j.board_id}/cards/#{j.card_id}"}
                      class="block truncate hover:underline"
                      title={j.title}
                    >
                      {j.title || "card ##{j.card_id}"}
                    </.link>
                  </td>
                  <td class="py-1.5 pr-2"><.outcome_chip job={j} /></td>
                  <td class="py-1.5">
                    <div class="flex items-center gap-2">
                      <span
                        class="h-1.5 w-24 overflow-hidden rounded-full bg-base-content/10"
                        aria-hidden="true"
                      >
                        <span
                          class={["block h-full rounded-full", outcome_bar(j.outcome)]}
                          style={"width: #{round((j.duration || 0) / @longest * 100)}%"}
                        ></span>
                      </span>
                      <span class="text-xs tabular-nums text-base-content/70">{duration(j.duration)}</span>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </.section>
    """
  end

  attr :runner, :map, required: true

  defp runner_card(assigns) do
    r = assigns.runner
    o = r.outcomes
    total = o.done + o.parked + o.failed + o.running

    assigns =
      assign(assigns,
        r: r,
        o: o,
        total: total,
        segments: segments(o, total)
      )

    ~H"""
    <div
      id={"runner-#{@r.id}"}
      data-status={@r.status}
      class="flex min-w-0 flex-[1_1_18rem] flex-col gap-3 rounded-box bg-base-200/60 p-3"
    >
      <div class="flex items-center gap-2">
        <.icon
          name={if @r.kind == "session", do: "hero-chat-bubble-left-right", else: "hero-cpu-chip"}
          class="size-5 shrink-0 text-base-content/60"
        />
        <div class="min-w-0 flex-1">
          <div class="truncate text-sm font-semibold">{@r.name}</div>
          <div class="text-2xs text-base-content/60">
            {if @r.kind == "session", do: "Claude session", else: "Runner"} · pool {@r.pool}
          </div>
        </div>
        <.chip :if={@r.status == "running"} tone={:primary} id={"runner-#{@r.id}-status"}>
          <span class="size-1.5 rounded-full bg-primary"></span> Running
        </.chip>
        <span
          :if={@r.status == "idle"}
          id={"runner-#{@r.id}-status"}
          class="rounded-full px-2 py-0.5 text-2xs font-medium ring-1 ring-base-content/20"
        >
          Idle
        </span>
        <.chip :if={@r.status == "offline"} id={"runner-#{@r.id}-status"} class="text-base-content/60">
          Offline
        </.chip>
      </div>

      <div
        :if={@r.current}
        id={"runner-#{@r.id}-current"}
        class="space-y-1.5 rounded-box bg-base-300/60 p-2.5"
      >
        <div class="text-2xs font-mono text-base-content/60">
          Job #{@r.current.job_id} · card #{@r.current.card_id}
        </div>
        <.link
          navigate={~p"/boards/#{@r.current.board_id}/cards/#{@r.current.card_id}"}
          class="block truncate text-sm font-medium hover:underline"
        >
          {@r.current.title}
        </.link>
        <div class="h-1.5 overflow-hidden rounded-full bg-base-content/10" aria-hidden="true">
          <div
            class="h-full rounded-full bg-primary"
            style={"width: #{elapsed_fill(@r.current.elapsed, @r.duration.p50)}%"}
          >
          </div>
        </div>
        <div class="text-2xs tabular-nums text-base-content/60">
          {duration(@r.current.elapsed)} elapsed · median job {duration(@r.duration.p50)}
        </div>
      </div>

      <dl class="grid grid-cols-2 gap-2 text-xs">
        <div>
          <dt class="text-2xs text-base-content/60">Queue wait P50</dt>
          <dd class="font-semibold tabular-nums">{duration(@r.queue_wait.p50)}</dd>
        </div>
        <div>
          <dt class="text-2xs text-base-content/60">Job success</dt>
          <dd class="font-semibold tabular-nums" id={"runner-#{@r.id}-success"}>
            {if @r.success_rate, do: "#{round(@r.success_rate * 100)}%", else: "–"}
          </dd>
        </div>
        <div>
          <dt class="text-2xs text-base-content/60">Human waits</dt>
          <dd class="tabular-nums">
            <span class="font-semibold">{@r.waits.opened}</span>
            <span :if={@r.waits.answer.p50} class="text-base-content/60">
              · answered in {duration(@r.waits.answer.p50)}
            </span>
          </dd>
        </div>
        <div>
          <dt class="text-2xs text-base-content/60">Cards reopened</dt>
          <dd class="tabular-nums">
            <span class="font-semibold">{@r.reopened.count}</span>
            <span :if={@r.reopened.card_ids != []} class="font-mono text-2xs text-base-content/60">
              {@r.reopened.card_ids |> Enum.uniq() |> Enum.map_join(" ", &"##{&1}")}
            </span>
          </dd>
        </div>
      </dl>

      <div>
        <div
          id={"runner-#{@r.id}-outcomes"}
          class="flex h-2 overflow-hidden rounded-full bg-base-content/10"
          role="img"
          aria-label={"Outcomes: #{@o.done} done, #{@o.parked} parked, #{@o.failed} failed, #{@o.running} running"}
        >
          <div
            :for={{key, tone, width} <- @segments}
            class={["h-full", tone]}
            style={"width: #{Float.round(width / 1, 2)}%"}
            data-outcome={key}
          >
          </div>
        </div>
        <div class="mt-1 flex flex-wrap gap-x-3 text-2xs tabular-nums text-base-content/70">
          <span>{@o.done} done</span>
          <span>{@o.parked} parked</span>
          <span>{@o.failed} failed</span>
          <span>{@o.running} running</span>
        </div>
      </div>
    </div>
    """
  end

  # The outcome bar's pieces, left to right; a zero takes no room.
  defp segments(o, total) do
    tones = [done: "bg-success", parked: "bg-warning", failed: "bg-error", running: "bg-primary"]

    for {key, tone} <- tones, Map.fetch!(o, key) > 0 do
      {key, tone, Map.fetch!(o, key) / max(total, 1) * 100}
    end
  end

  defp elapsed_fill(_elapsed, nil), do: 0
  defp elapsed_fill(_elapsed, 0), do: 100
  defp elapsed_fill(elapsed, median), do: round(min(elapsed / median, 1) * 100)

  attr :job, :map, required: true

  defp outcome_chip(assigns) do
    ~H"""
    <.chip :if={@job.outcome == "done"} tone={:success}>Done</.chip>
    <.chip :if={@job.outcome == "parked"} tone={:warning} title={@job.reason}>
      <span class="max-w-40 truncate">Parked{if @job.reason, do: ": #{@job.reason}"}</span>
    </.chip>
    <.chip :if={@job.outcome == "failed"} tone={:error} title={@job.reason}>Failed</.chip>
    <.chip :if={@job.outcome == "running"} tone={:primary}>Running</.chip>
    <.chip :if={@job.outcome == "cancelled"}>Cancelled</.chip>
    """
  end

  defp outcome_bar("done"), do: "bg-success"
  defp outcome_bar("parked"), do: "bg-warning"
  defp outcome_bar("failed"), do: "bg-error"
  defp outcome_bar("running"), do: "bg-primary"
  defp outcome_bar(_), do: "bg-base-content/40"

  ## Delivery (DORA) -----------------------------------------------------------

  @bands ~w(low medium high elite)

  attr :board, :any, required: true
  attr :dora, :map, default: nil, doc: "the report; nil while delivery metrics are off"

  attr :cycle_p50, :integer,
    default: nil,
    doc: "Pulse's start-to-done P50, for idea to production"

  @doc """
  The board's delivery numbers over DORA's own 30 days: four metric cards
  with their band, deploys per day, and idea to production in its parts.
  While delivery metrics are off, the nudge to turn them on instead.
  """
  def dora_section(%{dora: nil} = assigns) do
    ~H"""
    <.section id="dora" title="Delivery (DORA)">
      <p id="dora-off" class="text-sm text-base-content/70">
        Delivery metrics are off for this board. Turn them on in the
        <.link navigate={~p"/boards/#{@board}/settings?tab=features"} class="link">board's settings</.link>
        (Delivery metrics), or with <code class="font-mono text-xs">slipdock set-board {@board.code} --delivery-metrics</code>,
        and record deploys from CI to see deployment frequency, lead time, change failure rate
        and time to restore here.
      </p>
    </.section>
    """
  end

  def dora_section(assigns) do
    d = assigns.dora
    prev = d.previous.deployment_frequency.deploys

    assigns =
      assign(assigns,
        d: d,
        compare: prev > 0,
        note:
          "#{d.environment} · #{Calendar.strftime(d.since, "%-d %b")} to " <>
            "#{Calendar.strftime(d.until, "%-d %b")} (#{d.days} days)" <>
            if(prev > 0,
              do: "",
              else: " · no deploys recorded in the #{d.days} days before, so no comparison yet"
            ),
        shipped:
          d.commits_per_deploy && round(d.commits_per_deploy * d.deployment_frequency.deploys)
      )

    ~H"""
    <.section id="dora" title="Delivery (DORA)" note={@note}>
      <:aside>
        <span
          :if={@d.last_deploy}
          id="dora-last-deploy"
          class="rounded-full bg-base-200 px-2 py-0.5 font-mono text-2xs text-base-content/70"
        >
          Last deploy {@d.last_deploy.tag || String.slice(@d.last_deploy.sha || "", 0, 7)} · {Calendar.strftime(
            @d.last_deploy.at,
            "%-d %b %H:%M"
          )}
        </span>
      </:aside>
      <p :if={!@d.last_deploy} id="dora-no-deploys" class="text-sm text-base-content/70">
        Delivery metrics are on: no deploys recorded yet. Wrap your deploy step in CI with
        <code class="font-mono text-xs">slipdock deploy run</code>
        (board settings → Delivery metrics shows how).
      </p>
      <div :if={@d.last_deploy} class="space-y-4">
        <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <.metric
            id="dora-frequency"
            label="Deployment frequency"
            value={"#{@d.deployment_frequency.per_day} a day"}
            detail={"#{@d.deployment_frequency.deploys} #{plural(@d.deployment_frequency.deploys, "deploy")} · #{@d.deployment_frequency.per_week} a week"}
            trend={
              @compare &&
                trend(@d.deployment_frequency.deploys, @d.previous.deployment_frequency.deploys)
            }
            band={@d.deployment_frequency.band}
            target="Elite: at least once a day"
          />
          <.metric
            id="dora-lead-time"
            label="Lead time for changes"
            value={duration(@d.lead_time.p50)}
            detail={"P85 #{duration(@d.lead_time.p85)} · #{@d.lead_time.commits} #{plural(@d.lead_time.commits, "commit")}"}
            trend={@compare && trend(@d.lead_time.p50, @d.previous.lead_time.p50, &duration/1)}
            band={@d.lead_time.band}
            target="Elite: under a day"
          />
          <.metric
            id="dora-cfr"
            label="Change failure rate"
            value={
              if @d.change_failure_rate.rate,
                do: "#{round(@d.change_failure_rate.rate * 100)}%",
                else: "–"
            }
            detail={"#{@d.change_failure_rate.failed} failed of #{@d.change_failure_rate.deploys} #{plural(@d.change_failure_rate.deploys, "deploy")}"}
            trend={
              @compare &&
                trend(
                  @d.change_failure_rate.rate,
                  @d.previous.change_failure_rate.rate,
                  &"#{round(&1 * 100)}%"
                )
            }
            band={@d.change_failure_rate.band}
            target="Elite: 5% or less"
          />
          <.metric
            :if={@d.time_to_restore.restores > 0}
            id="dora-restore"
            label="Time to restore"
            value={duration(@d.time_to_restore.p50)}
            detail={"P85 #{duration(@d.time_to_restore.p85)} · #{@d.time_to_restore.restores} #{plural(@d.time_to_restore.restores, "restore")}"}
            trend={
              @compare && trend(@d.time_to_restore.p50, @d.previous.time_to_restore.p50, &duration/1)
            }
            band={@d.time_to_restore.band}
            target="Elite: under an hour"
          />
          <.metric
            :if={@d.time_to_restore.restores == 0}
            id="dora-restore"
            label="Time to restore"
            value="n/a"
            detail="No restores in this window"
            unscored="No incidents"
            target="Scored after the first incident."
          />
        </div>

        <div class="grid gap-4 lg:grid-cols-2">
          <SlipdockWeb.BoardLive.VisualiseCharts.deploys_chart dora={@d} />
          <.idea_to_production d={@d} cycle_p50={@cycle_p50} shipped={@shipped} />
        </div>
      </div>
    </.section>
    """
  end

  # ↑ or ↓ against the window before, with what it was; the arrow says which
  # way it moved, not whether that is good.
  defp trend(now, before, show \\ &to_string/1)
  defp trend(nil, _before, _show), do: nil
  defp trend(_now, nil, _show), do: nil
  defp trend(same, same, _show), do: "same as before"
  defp trend(now, before, show) when now > before, do: "↑ from #{show.(before)}"
  defp trend(_now, before, show), do: "↓ from #{show.(before)}"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :detail, :string, required: true
  attr :trend, :any, default: nil
  attr :band, :string, default: nil
  attr :unscored, :string, default: "Not scored yet"
  attr :target, :string, required: true

  defp metric(assigns) do
    level = if assigns.band, do: Enum.find_index(@bands, &(&1 == assigns.band)) + 1, else: 0
    assigns = assign(assigns, level: level, bands: @bands)

    ~H"""
    <div
      id={@id}
      data-band={@band || "none"}
      class="flex min-w-0 flex-col gap-2 rounded-box bg-base-200/60 p-3"
    >
      <div class="flex items-start justify-between gap-2">
        <div class="text-2xs font-medium uppercase tracking-wide text-base-content/60">{@label}</div>
        <span
          :if={@band}
          class={[
            "badge badge-xs badge-soft font-medium",
            SlipdockWeb.BoardLive.BoardView.dora_band_class(@band)
          ]}
          title={"DORA band: #{@band}"}
        >
          {String.capitalize(@band)}
        </span>
        <.chip :if={!@band}>{@unscored}</.chip>
      </div>
      <div class="text-2xl font-semibold tabular-nums" data-value>{@value}</div>
      <div class="text-xs tabular-nums text-base-content/60">
        {@detail}<span :if={@trend}> · {@trend}</span>
      </div>
      <div>
        <div class="grid grid-cols-4 gap-0.5" role="img" aria-label={scale_label(@band)}>
          <span
            :for={{band, i} <- Enum.with_index(@bands, 1)}
            class={[
              "h-1.5 first:rounded-l-full last:rounded-r-full",
              if(i <= @level, do: scale_fill(@band), else: "bg-base-content/10")
            ]}
            data-filled={to_string(i <= @level)}
            data-scale={band}
          ></span>
        </div>
        <div class="mt-0.5 grid grid-cols-4 text-2xs text-base-content/60">
          <span>Low</span><span>Medium</span><span>High</span><span>Elite</span>
        </div>
      </div>
      <div class="text-2xs text-base-content/60">{@target}</div>
    </div>
    """
  end

  defp scale_label(nil), do: "Not scored on the Low to Elite scale"
  defp scale_label(band), do: "#{String.capitalize(band)} on the Low, Medium, High, Elite scale"

  defp scale_fill("elite"), do: "bg-success"
  defp scale_fill("high"), do: "bg-info"
  defp scale_fill("medium"), do: "bg-warning"
  defp scale_fill(_), do: "bg-error"

  attr :d, :map, required: true
  attr :cycle_p50, :integer, default: nil
  attr :shipped, :integer, default: nil

  defp idea_to_production(assigns) do
    d = assigns.d

    rows = [
      {"commit-deploy", "Commit to deploy", d.lead_time.p50},
      {"start-done", "Start to done", assigns.cycle_p50},
      {"card-production", "Card to production", d.idea_to_production.p50}
    ]

    top = rows |> Enum.map(&(elem(&1, 2) || 0)) |> Enum.max() |> max(1)
    assigns = assign(assigns, rows: rows, top: top)

    ~H"""
    <div
      id="idea-to-production"
      class="flex min-w-0 flex-col gap-3 rounded-box bg-base-100 p-4 shadow-sm sm:p-5"
    >
      <div>
        <h3 class="text-base font-semibold">From idea to production</h3>
        <p class="text-xs text-base-content/60">Medians on one scale.</p>
      </div>
      <ul class="space-y-2">
        <li
          :for={{key, label, secs} <- @rows}
          id={"itp-#{key}"}
          class="grid grid-cols-[8rem_1fr_4.5rem] items-center gap-2 text-sm"
        >
          <span class="truncate text-xs">{label}</span>
          <span class="h-2 overflow-hidden rounded-full bg-base-content/10" aria-hidden="true">
            <span
              class="block h-full rounded-full bg-primary/70"
              style={"width: #{round((secs || 0) / @top * 100)}%"}
            ></span>
          </span>
          <span class="text-right text-xs tabular-nums">{duration(secs)}</span>
        </li>
      </ul>
      <p class="text-2xs text-base-content/60">
        Card to production covers {@d.idea_to_production.cards} {plural(
          @d.idea_to_production.cards,
          "card"
        )} first shipped in the window{if @d.idea_to_production.from_created > 0,
          do: ", #{@d.idea_to_production.from_created} counted from when made"}; start to done is the board's cycle time over 90 days.
      </p>
      <dl class="grid grid-cols-2 gap-3 border-t border-base-content/10 pt-3 text-xs">
        <div id="dora-rework">
          <dt class="text-2xs text-base-content/60">Rework rate</dt>
          <dd>
            <span class="font-semibold tabular-nums">
              {if @d.rework_rate.rate, do: "#{round(@d.rework_rate.rate * 100)}%", else: "–"}
            </span>
            <span class="text-base-content/60">{@d.rework_rate.rework} of {@d.rework_rate.deploys} deploys</span>
          </dd>
        </div>
        <div id="dora-commits">
          <dt class="text-2xs text-base-content/60">Commits shipped</dt>
          <dd>
            <span class="font-semibold tabular-nums">{@shipped || 0}</span>
            <span :if={@d.commits_per_deploy} class="text-base-content/60">
              {@d.commits_per_deploy} a deploy
            </span>
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc false
  def plural(1, word), do: word
  def plural(_, word), do: word <> "s"
end

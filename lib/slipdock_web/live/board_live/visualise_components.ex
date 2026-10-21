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

  @doc false
  def plural(1, word), do: word
  def plural(_, word), do: word <> "s"
end

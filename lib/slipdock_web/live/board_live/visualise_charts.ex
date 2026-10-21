defmodule SlipdockWeb.BoardLive.VisualiseCharts do
  @moduledoc """
  The Visualise page's four trend charts (#1191) from `Slipdock.Flow.history/2`:
  cumulative flow, velocity, backlog burndown and cycle time. Inline SVG
  drawn on the server, as the sprint charts (`SlipdockWeb.SprintChartComponents`)
  are, with the axis labels in HTML beside the plot so they stay crisp and
  readable at any width.

  The plot is a fixed `#{600}×#{180}` viewBox that scales with its box,
  keeping its shape, so a label placed at a percentage of the box sits at
  the same place in the drawing. Day `i` of `n` is drawn at the middle of
  its slot, `(i + 0.5) / n` across, for bars and lines alike.

  The geometry (`ticks/1`, `area_paths/2`, `line_path/2`, `log_y/1`, …) is
  plain functions, so it can be tested without rendering.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.BoardLive.VisualiseComponents, only: [duration: 1]

  @w 600
  @h 180

  @doc "The drawing's size in SVG units: `{width, height}`."
  def size, do: {@w, @h}

  ## Geometry -------------------------------------------------------------------

  @doc """
  Round ticks for an axis from 0 up to at least `max`: about four steps of
  1, 2 or 5 times a power of ten, never less than 1. `{top, ticks}`.
  """
  def ticks(max) when max <= 0, do: {1, [0, 1]}

  def ticks(max) do
    raw = max / 4
    mag = :math.pow(10, Float.floor(:math.log10(raw)))
    norm = raw / mag

    step =
      cond do
        norm <= 1 -> 1
        norm <= 2 -> 2
        norm <= 5 -> 5
        true -> 10
      end * mag

    step = if step < 1, do: 1, else: round(step)
    top = ceil(max / step) * step
    {top, Enum.to_list(0..top//step)}
  end

  @doc "The x of day `i` of `n`: the middle of its slot."
  def x(i, n), do: r((i + 0.5) * @w / max(n, 1))

  @doc "The y of `v` on an axis from 0 to `top`."
  def y(v, top), do: r(@h - v / max(top, 1) * @h)

  @doc "A polyline's points through `values`, one a day, on an axis to `top`."
  def line_path(values, top) do
    n = length(values)

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {v, i} -> "#{x(i, n)},#{y(v, top)}" end)
  end

  @doc """
  The stacked areas of a cumulative flow chart: `bands` is a list of
  `{name, values}` from the bottom up. Each area is the closed path between
  the running total below it and the running total with it. `{name, path}`.
  """
  def area_paths(bands, top) do
    n = bands |> List.first({nil, []}) |> elem(1) |> length()
    zero = List.duplicate(0, n)

    {paths, _} =
      Enum.map_reduce(bands, zero, fn {name, values}, below ->
        above = Enum.zip_with(below, values, &(&1 + &2))
        upper = above |> Enum.with_index() |> Enum.map(fn {v, i} -> "#{x(i, n)},#{y(v, top)}" end)

        lower =
          below
          |> Enum.with_index()
          |> Enum.reverse()
          |> Enum.map(fn {v, i} -> "#{x(i, n)},#{y(v, top)}" end)

        {{name, "M" <> Enum.join(upper ++ lower, " L") <> " Z"}, above}
      end)

    paths
  end

  @doc """
  The trailing mean of `values` over `span` entries (fewer at the start),
  to one decimal place.
  """
  def rolling(values, span) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {_, i} ->
      window = Enum.slice(values, max(i - span + 1, 0)..i//1)
      Float.round(Enum.sum(window) / length(window), 1)
    end)
  end

  @log_min 60
  @log_max 86_400

  @doc """
  The y of `seconds` on the cycle time chart's log scale, from a minute at
  the bottom to a day at the top; anything outside is held to the edge.
  """
  def log_y(seconds) do
    s = seconds |> max(@log_min) |> min(@log_max)
    span = :math.log10(@log_max) - :math.log10(@log_min)
    r(@h - (:math.log10(s) - :math.log10(@log_min)) / span * @h)
  end

  @doc "The log scale's labels: `{label, seconds}`."
  def log_ticks, do: [{"1m", 60}, {"10m", 600}, {"1h", 3600}, {"1d", 86_400}]

  @doc """
  Five dates spread across `dates` (all of them when there are fewer), each
  `{label, percent across}`.
  """
  def date_labels(dates) do
    n = length(dates)

    picks =
      if n <= 5,
        do: Enum.to_list(0..(n - 1)//1),
        else: Enum.map(0..4, &round(&1 * (n - 1) / 4))

    Enum.map(picks, fn i ->
      {Calendar.strftime(Enum.at(dates, i), "%-d %b"), pct((i + 0.5) / n)}
    end)
  end

  @doc "A small, steady sideways nudge for a dot, from its card id, within its day."
  def jitter(id, n), do: r((:erlang.phash2(id, 1000) / 1000 - 0.5) * 0.6 * @w / max(n, 1))

  defp r(v), do: Float.round(v / 1, 1)
  defp pct(f), do: Float.round(f * 100, 2)

  ## Charts -----------------------------------------------------------------

  attr :history, :map, required: true, doc: "from Slipdock.Flow.history/2"

  @doc "The four charts, two up (one up on phones)."
  def trends(assigns) do
    ~H"""
    <section id="trends" aria-labelledby="trends-title" class="space-y-3">
      <div class="flex flex-wrap items-baseline gap-x-2 px-1">
        <h2 id="trends-title" class="text-base font-semibold">Trends</h2>
        <span class="text-xs text-base-content/60">
          Last {@history.days} days, {Calendar.strftime(@history.since, "%-d %b")} to {Calendar.strftime(
            @history.until,
            "%-d %b"
          )}
        </span>
      </div>
      <div class="grid gap-4 lg:grid-cols-2">
        <.cumulative_flow history={@history} />
        <.velocity history={@history} />
        <.burndown history={@history} />
        <.cycle_time history={@history} />
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :explain, :string, required: true
  attr :empty, :string, default: nil, doc: "the line shown instead of the chart, when empty"
  attr :label, :string, default: nil, doc: "the chart's takeaway, for its aria-label"
  attr :yticks, :list, default: [], doc: "`{label, percent down}`"
  attr :dates, :list, default: []
  slot :legend
  slot :stat
  slot :inner_block

  defp chart(assigns) do
    assigns = assign(assigns, w: @w, h: @h)

    ~H"""
    <div id={@id} class="flex min-w-0 flex-col gap-2 rounded-box bg-base-100 p-4 shadow-sm sm:p-5">
      <div class="flex flex-wrap items-start justify-between gap-x-3 gap-y-1">
        <div class="min-w-0">
          <h3 class="text-base font-semibold">{@title}</h3>
          <p class="text-xs text-base-content/60">{@explain}</p>
        </div>
        <div :if={@stat != [] and is_nil(@empty)} class="text-right text-xs tabular-nums">
          {render_slot(@stat)}
        </div>
      </div>
      <p :if={@empty} id={"#{@id}-empty"} class="py-6 text-sm text-base-content/60">{@empty}</p>
      <div
        :if={is_nil(@empty) and @legend != []}
        class="flex flex-wrap gap-x-3 gap-y-1 text-2xs text-base-content/70"
      >
        {render_slot(@legend)}
      </div>
      <div :if={is_nil(@empty)} class="grid grid-cols-[auto_1fr] gap-x-2">
        <div
          class="relative w-8 text-right text-2xs tabular-nums text-base-content/60"
          aria-hidden="true"
        >
          <span
            :for={{label, top} <- @yticks}
            class="absolute right-0 -translate-y-1/2 leading-none"
            style={"top: #{top}%"}
          >
            {label}
          </span>
        </div>
        <svg
          viewBox={"0 0 #{@w} #{@h}"}
          class="block h-auto w-full overflow-visible"
          role="img"
          aria-label={@label}
        >
          <line
            :for={{_, top} <- @yticks}
            x1="0"
            x2={@w}
            y1={top * @h / 100}
            y2={top * @h / 100}
            class="stroke-base-content/10"
            stroke-width="1"
            vector-effect="non-scaling-stroke"
          />
          {render_slot(@inner_block)}
        </svg>
        <div></div>
        <div class="relative mt-1 h-4 text-2xs tabular-nums text-base-content/60" aria-hidden="true">
          <span
            :for={{label, left} <- @dates}
            class="absolute -translate-x-1/2 whitespace-nowrap"
            style={"left: #{left}%"}
          >
            {label}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp yticks(ticks, top),
    do: Enum.map(ticks, &{to_string(&1), Float.round((1 - &1 / top) * 100, 2)})

  defp dates(history), do: Enum.map(history.series, & &1.date)

  attr :history, :map, required: true

  def cumulative_flow(assigns) do
    series = assigns.history.series

    bands = [
      {"done", Enum.map(series, & &1.done)},
      {"doing", Enum.map(series, & &1.doing)},
      {"ready", Enum.map(series, & &1.ready)},
      {"backlog", Enum.map(series, & &1.backlog)}
    ]

    totals = Enum.map(series, &(&1.done + &1.doing + &1.ready + &1.backlog))
    {top, ticks} = ticks(Enum.max(totals, fn -> 0 end))
    last = List.last(series)

    assigns =
      assign(assigns,
        empty: Enum.all?(totals, &(&1 == 0)),
        paths: area_paths(bands, top),
        yticks: yticks(ticks, top),
        dates: date_labels(dates(assigns.history)),
        label:
          last &&
            "Cumulative flow: today #{last.backlog} in backlog, #{last.ready} ready, " <>
              "#{last.doing} in progress and #{last.done} done since the window began"
      )

    ~H"""
    <.chart
      id="chart-cfd"
      title="Cumulative flow"
      explain="Even bands mean steady flow; a widening doing band means work is piling up."
      empty={if @empty, do: "No cards on the board's lists in this window."}
      label={@label}
      yticks={@yticks}
      dates={@dates}
    >
      <:legend>
        <.key class="bg-base-content/15">Backlog</.key>
        <.key class="bg-base-content/30">Ready</.key>
        <.key class="bg-primary/60">Doing</.key>
        <.key class="bg-success/60">Done</.key>
      </:legend>
      <path :for={{name, d} <- @paths} d={d} class={band_class(name)} data-band={name} />
    </.chart>
    """
  end

  defp band_class("done"), do: "fill-success/60"
  defp band_class("doing"), do: "fill-primary/60"
  defp band_class("ready"), do: "fill-base-content/30"
  defp band_class("backlog"), do: "fill-base-content/15"

  attr :class, :string, required: true
  attr :shape, :atom, default: :swatch, values: [:swatch, :line, :dashed]
  slot :inner_block, required: true

  # A legend entry: a swatch for an area or bar, a line (solid or dashed,
  # so the P85 line is told apart without its colour) for a line.
  defp key(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1">
      <span class={[
        "inline-block w-3",
        @shape == :swatch && "h-2 rounded-sm",
        @shape == :line && "h-0 border-t-2",
        @shape == :dashed && "h-0 border-t-2 border-dashed",
        @class
      ]}></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :dora, :map, required: true, doc: "a Slipdock.Dora report, with `per_day`"

  @doc "Deploys per day over DORA's window: succeeded bars, failures stacked on top."
  def deploys_chart(assigns) do
    days = assigns.dora.per_day
    n = length(days)
    succeeded = Enum.sum_by(days, & &1.succeeded)
    failed = Enum.sum_by(days, & &1.failed)
    {top, ticks} = ticks(Enum.max(Enum.map(days, &(&1.succeeded + &1.failed)), fn -> 0 end))
    bar = min(@w / max(n, 1) * 0.6, 24)

    assigns =
      assign(assigns,
        empty: succeeded + failed == 0,
        succeeded: succeeded,
        failed: failed,
        bar: Float.round(bar / 1, 1),
        bars:
          for {d, i} <- Enum.with_index(days), d.succeeded + d.failed > 0 do
            ok_y = y(d.succeeded, top)
            all_y = y(d.succeeded + d.failed, top)

            %{
              x: Float.round(x(i, n) - bar / 2, 1),
              ok_y: ok_y,
              ok_h: Float.round(@h - ok_y, 1),
              fail_y: all_y,
              fail_h: Float.round(ok_y - all_y, 1),
              date: d.date,
              d: d
            }
          end,
        yticks: yticks(ticks, top),
        dates: date_labels(Enum.map(days, & &1.date)),
        label:
          "Deploys per day: #{succeeded + failed} deploys, #{succeeded} succeeded, #{failed} failed"
      )

    ~H"""
    <.chart
      id="chart-deploys"
      title="Deploys per day"
      explain="Finished deploys each day; failed ones (failed, rolled back or causing an incident) stacked on top."
      empty={if @empty, do: "No deploys in this window."}
      label={@label}
      yticks={@yticks}
      dates={@dates}
    >
      <:legend>
        <.key class="bg-success/70">{@succeeded + @failed} deploys, {@succeeded} succeeded</.key>
        <.key class="bg-error/70">{@failed} failed</.key>
      </:legend>
      <g :for={b <- @bars}>
        <rect
          x={b.x}
          y={b.ok_y}
          width={@bar}
          height={b.ok_h}
          class="fill-success/70"
          data-day={b.date}
        >
          <title>
            {Calendar.strftime(b.date, "%-d %b")}: {b.d.succeeded} succeeded, {b.d.failed} failed
          </title>
        </rect>
        <rect
          :if={b.fail_h > 0}
          x={b.x}
          y={b.fail_y}
          width={@bar}
          height={b.fail_h}
          class="fill-error/70"
          data-failed={b.date}
        />
      </g>
    </.chart>
    """
  end

  attr :history, :map, required: true

  def velocity(assigns) do
    h = assigns.history
    weekly = h.days == 90

    {labels, values} =
      if weekly,
        do: {Enum.map(h.weeks, & &1.start), Enum.map(h.weeks, & &1.completed)},
        else: {Enum.map(h.series, & &1.date), Enum.map(h.series, & &1.completed)}

    n = length(values)
    unit = if weekly, do: "week", else: "day"
    average = if n > 0, do: Float.round(Enum.sum(values) / n, 1), else: 0.0
    roll = rolling(values, if(weekly, do: 4, else: 7))
    {top, ticks} = ticks(Enum.max(values ++ roll, fn -> 0 end))
    slot = @w / max(n, 1)
    bar = min(slot * 0.6, 24)

    assigns =
      assign(assigns,
        empty: Enum.sum(values) == 0,
        unit: unit,
        average: average,
        bars:
          for {v, i} <- Enum.with_index(values) do
            %{x: x(i, n) - bar / 2, y: y(v, top), height: Float.round(@h - y(v, top), 1), v: v}
          end,
        bar: Float.round(bar / 1, 1),
        roll: line_path(roll, top),
        yticks: yticks(ticks, top),
        dates: date_labels(labels),
        label:
          "Velocity: #{Enum.sum(values)} cards completed, #{average} a #{unit} on average" <>
            if(weekly, do: ", by week", else: "")
      )

    ~H"""
    <.chart
      id="chart-velocity"
      title="Velocity"
      explain={"Cards completed each #{@unit}, with the #{if @unit == "week", do: "4-week", else: "7-day"} rolling average."}
      empty={if @empty, do: "Nothing was completed in this window."}
      label={@label}
      yticks={@yticks}
      dates={@dates}
    >
      <:stat>
        <span class="font-semibold">{@average}</span>
        <span class="text-base-content/60">a {@unit} on average</span>
      </:stat>
      <:legend>
        <.key class="bg-primary/50">Completed</.key>
        <.key class="border-base-content/70" shape={:line}>Rolling average</.key>
      </:legend>
      <rect
        :for={b <- @bars}
        x={b.x}
        y={b.y}
        width={@bar}
        height={b.height}
        rx="2"
        class="fill-primary/50"
      />
      <polyline
        points={@roll}
        fill="none"
        class="stroke-base-content/70"
        stroke-width="2"
        vector-effect="non-scaling-stroke"
        data-line="rolling"
      />
    </.chart>
    """
  end

  attr :history, :map, required: true

  def burndown(assigns) do
    series = assigns.history.series
    open = Enum.map(series, & &1.open)
    added = Enum.map(series, & &1.added)
    n = length(series)
    first = List.first(open, 0)
    now = List.last(open, 0)
    {top, ticks} = ticks(Enum.max(open ++ added, fn -> 0 end))
    net = if n > 1, do: Float.round((first - now) / (n - 1), 1), else: 0.0
    slot = @w / max(n, 1)
    bar = min(slot * 0.5, 16)

    assigns =
      assign(assigns,
        empty: Enum.all?(open ++ added, &(&1 == 0)),
        open_line: line_path(open, top),
        even: "#{x(0, n)},#{y(first, top)} #{x(n - 1, n)},#{y(0, top)}",
        bars:
          for {v, i} <- Enum.with_index(added), v > 0 do
            %{x: x(i, n) - bar / 2, y: y(v, top), height: Float.round(@h - y(v, top), 1)}
          end,
        bar: Float.round(bar / 1, 1),
        net: net,
        now: now,
        yticks: yticks(ticks, top),
        dates: date_labels(dates(assigns.history)),
        label:
          "Backlog burndown: #{now} open now, from #{first}; " <>
            "#{Enum.sum(added)} added; net burn #{net} a day"
      )

    ~H"""
    <.chart
      id="chart-burndown"
      title="Backlog burndown"
      explain="Open cards left each day against an even burn to zero, with the scope added."
      empty={if @empty, do: "No open cards in this window."}
      label={@label}
      yticks={@yticks}
      dates={@dates}
    >
      <:stat>
        <div>
          <span class="font-semibold">{@net}</span>
          <span class="text-base-content/60">net burn a day</span>
        </div>
        <div>
          <span class="font-semibold">{@now}</span> <span class="text-base-content/60">open now</span>
        </div>
      </:stat>
      <:legend>
        <.key class="border-primary" shape={:line}>Open cards</.key>
        <.key class="border-base-content/50" shape={:dashed}>Even burn</.key>
        <.key class="bg-warning/40">Added</.key>
      </:legend>
      <rect
        :for={b <- @bars}
        x={b.x}
        y={b.y}
        width={@bar}
        height={b.height}
        rx="2"
        class="fill-warning/40"
      />
      <polyline
        points={@even}
        fill="none"
        stroke-dasharray="6 5"
        class="stroke-base-content/50"
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
        data-line="even"
      />
      <polyline
        points={@open_line}
        fill="none"
        class="stroke-primary"
        stroke-width="2"
        vector-effect="non-scaling-stroke"
        data-line="open"
      />
    </.chart>
    """
  end

  attr :history, :map, required: true

  def cycle_time(assigns) do
    h = assigns.history
    n = length(h.series)

    dots =
      for f <- h.finished do
        day = f.completed_at |> DateTime.shift_zone!(h.timezone) |> DateTime.to_date()
        i = Date.diff(day, h.since)

        %{
          id: f.id,
          title: f.title,
          x: r(x(i, n) + jitter(f.id, n)),
          y: log_y(f.cycle_seconds),
          s: f.cycle_seconds
        }
      end

    assigns =
      assign(assigns,
        w: @w,
        dots: dots,
        p50: h.cycle.p50,
        p85: h.cycle.p85,
        p50_y: h.cycle.p50 && log_y(h.cycle.p50),
        p85_y: h.cycle.p85 && log_y(h.cycle.p85),
        yticks: Enum.map(log_ticks(), fn {l, s} -> {l, Float.round(log_y(s) / @h * 100, 2)} end),
        dates: date_labels(dates(h)),
        label:
          "Cycle time: #{length(dots)} cards finished, half within #{duration(h.cycle.p50)}, " <>
            "85% within #{duration(h.cycle.p85)}"
      )

    ~H"""
    <.chart
      id="chart-cycle"
      title="Cycle time"
      explain="One dot per finished card: start to done, on a log scale held to a minute and a day."
      empty={if @dots == [], do: "No cards were finished in this window."}
      label={@label}
      yticks={@yticks}
      dates={@dates}
    >
      <:legend>
        <.key class="bg-primary/50">A finished card</.key>
        <.key class="border-success" shape={:line}>P50 {duration(@p50)}</.key>
        <.key class="border-warning" shape={:dashed}>P85 {duration(@p85)}</.key>
      </:legend>
      <circle :for={d <- @dots} cx={d.x} cy={d.y} r="4" class="fill-primary/50" data-card={d.id}>
        <title>#{d.id} {d.title}: {duration(d.s)}</title>
      </circle>
      <line
        :if={@p50_y}
        x1="0"
        x2={@w}
        y1={@p50_y}
        y2={@p50_y}
        class="stroke-success"
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
        data-line="p50"
      />
      <line
        :if={@p85_y}
        x1="0"
        x2={@w}
        y1={@p85_y}
        y2={@p85_y}
        stroke-dasharray="6 5"
        class="stroke-warning"
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
        data-line="p85"
      />
    </.chart>
    """
  end
end

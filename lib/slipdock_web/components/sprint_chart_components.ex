defmodule SlipdockWeb.SprintChartComponents do
  @moduledoc """
  A sprint's burndown and a sprint board's velocity, drawn as inline SVG
  from `Slipdock.Sprints.burndown/2` and `Slipdock.Sprints.velocity/2`.
  """
  use SlipdockWeb, :html

  # The drawing area, in SVG units; the SVG scales to its container.
  @w 560
  @h 200
  @left 32
  @right 12
  @top 12
  @bottom 28

  attr :chart, :map, required: true, doc: "from Slipdock.Sprints.burndown/2"

  def burndown_chart(assigns) do
    chart = assigns.chart
    days = chart.days
    n = length(days)
    top = max(chart.total, 1)

    x = fn i -> @left + if(n > 1, do: i * (@w - @left - @right) / (n - 1), else: 0) end
    y = fn v -> @top + (@h - @top - @bottom) * (1 - v / top) end

    actual =
      days
      |> Enum.with_index()
      |> Enum.reject(fn {d, _} -> is_nil(d.remaining) end)
      |> Enum.map(fn {d, i} -> {x.(i), y.(d.remaining), d} end)

    assigns =
      assign(assigns,
        w: @w,
        h: @h,
        left: @left,
        right: @right,
        base: @h - @bottom,
        top_y: @top,
        top: top,
        ideal:
          days
          |> Enum.with_index()
          |> Enum.map_join(" ", fn {d, i} -> point(x.(i), y.(d.ideal)) end),
        actual: actual,
        line: Enum.map_join(actual, " ", fn {px, py, _} -> point(px, py) end),
        first: List.first(days),
        last: List.last(days)
      )

    ~H"""
    <figure class="space-y-1">
      <figcaption class="flex items-baseline justify-between gap-2 text-sm">
        <span class="font-semibold">Burndown · {@chart.sprint.title}</span>
        <span class="text-base-content/60">{@chart.done} of {@chart.total} cards done</span>
      </figcaption>
      <p :if={@chart.total == 0} class="text-sm text-base-content/60">
        Nothing in this sprint yet — add cards to it and they burn down here.
      </p>
      <svg
        :if={@chart.total > 0}
        id={"burndown-#{@chart.sprint.id}"}
        viewBox={"0 0 #{@w} #{@h}"}
        class="w-full"
        role="img"
        aria-label={"Burndown for #{@chart.sprint.title}"}
      >
        <line x1={@left} y1={@base} x2={@w - @right} y2={@base} class="stroke-base-content/30" />
        <line x1={@left} y1={@top_y} x2={@left} y2={@base} class="stroke-base-content/30" />
        <text x={@left - 6} y={@top_y + 4} text-anchor="end" class="fill-base-content/60 text-[10px]">
          {@top}
        </text>
        <text x={@left - 6} y={@base} text-anchor="end" class="fill-base-content/60 text-[10px]">
          0
        </text>
        <text x={@left} y={@h - 8} class="fill-base-content/60 text-[10px]">
          {Calendar.strftime(@first.date, "%-d %b")}
        </text>
        <text x={@w - @right} y={@h - 8} text-anchor="end" class="fill-base-content/60 text-[10px]">
          {Calendar.strftime(@last.date, "%-d %b")}
        </text>
        <polyline
          points={@ideal}
          fill="none"
          stroke-dasharray="4 4"
          class="stroke-base-content/40"
          stroke-width="1.5"
        />
        <polyline
          :if={@actual != []}
          points={@line}
          fill="none"
          class="stroke-primary"
          stroke-width="2"
        />
        <circle :for={{px, py, d} <- @actual} cx={px} cy={py} r="3" class="fill-primary">
          <title>{Calendar.strftime(d.date, "%a %-d %b")}: {d.remaining} left</title>
        </circle>
      </svg>
      <p :if={@chart.total > 0} class="flex gap-4 text-xs text-base-content/60">
        <span><span class="text-primary">━</span> cards left</span>
        <span>╌ ideal</span>
      </p>
    </figure>
    """
  end

  attr :velocity, :map, required: true, doc: "from Slipdock.Sprints.velocity/2"

  def velocity_chart(assigns) do
    sprints = assigns.velocity.sprints
    n = max(length(sprints), 1)
    top = sprints |> Enum.map(& &1.committed) |> Enum.max(fn -> 0 end) |> max(1)
    slot = (@w - @left - @right) / n
    bar = min(slot * 0.35, 28)
    y = fn v -> @top + (@h - @top - @bottom) * (1 - v / top) end

    bars =
      sprints
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        mid = @left + slot * (i + 0.5)

        %{
          sprint: s,
          mid: mid,
          committed: {mid - bar, y.(s.committed)},
          completed: {mid, y.(s.completed)}
        }
      end)

    assigns =
      assign(assigns,
        w: @w,
        h: @h,
        left: @left,
        right: @right,
        base: @h - @bottom,
        top_y: @top,
        top: top,
        bar: bar,
        bars: bars,
        average_y: assigns.velocity.average && y.(assigns.velocity.average)
      )

    ~H"""
    <figure class="space-y-1">
      <figcaption class="flex items-baseline justify-between gap-2 text-sm">
        <span class="font-semibold">Velocity</span>
        <span :if={@velocity.average} class="text-base-content/60">
          {@velocity.average} cards a sprint, on average
        </span>
      </figcaption>
      <p :if={@velocity.sprints == []} class="text-sm text-base-content/60">
        No sprints yet.
      </p>
      <svg
        :if={@velocity.sprints != []}
        id="velocity-chart"
        viewBox={"0 0 #{@w} #{@h}"}
        class="w-full"
        role="img"
        aria-label="Cards committed and completed per sprint"
      >
        <line x1={@left} y1={@base} x2={@w - @right} y2={@base} class="stroke-base-content/30" />
        <text x={@left - 6} y={@top_y + 4} text-anchor="end" class="fill-base-content/60 text-[10px]">
          {@top}
        </text>
        <text x={@left - 6} y={@base} text-anchor="end" class="fill-base-content/60 text-[10px]">
          0
        </text>
        <g :for={b <- @bars}>
          <rect
            x={elem(b.committed, 0)}
            y={elem(b.committed, 1)}
            width={@bar}
            height={@base - elem(b.committed, 1)}
            class="fill-base-content/20"
          >
            <title>{b.sprint.title}: {b.sprint.committed} committed</title>
          </rect>
          <rect
            x={elem(b.completed, 0)}
            y={elem(b.completed, 1)}
            width={@bar}
            height={@base - elem(b.completed, 1)}
            class={if b.sprint.finished, do: "fill-primary", else: "fill-primary/50"}
          >
            <title>{b.sprint.title}: {b.sprint.completed} completed</title>
          </rect>
          <text x={b.mid} y={@h - 8} text-anchor="middle" class="fill-base-content/60 text-[10px]">
            {short(b.sprint.title)}
          </text>
        </g>
        <line
          :if={@average_y}
          x1={@left}
          y1={@average_y}
          x2={@w - @right}
          y2={@average_y}
          stroke-dasharray="4 4"
          class="stroke-secondary"
        />
      </svg>
      <p :if={@velocity.sprints != []} class="flex flex-wrap gap-4 text-xs text-base-content/60">
        <span><span class="text-base-content/30">■</span> committed</span>
        <span><span class="text-primary">■</span> completed</span>
        <span :if={@velocity.average}><span class="text-secondary">╌</span> average</span>
      </p>
    </figure>
    """
  end

  defp point(x, y), do: "#{Float.round(x / 1, 1)},#{Float.round(y / 1, 1)}"

  # "Sprint 12" fits under its bar as "S12"; anything else is cut short.
  defp short(title) do
    case Regex.run(~r/^\s*sprint\s+(\d+)\b/i, title) do
      [_, n] -> "S#{n}"
      _ -> String.slice(title, 0, 8)
    end
  end
end

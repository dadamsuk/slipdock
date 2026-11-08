defmodule Slipdock.Overseer.Pacing do
  @moduledoc """
  When the overseer's next pass comes (#2068, the owner's call of
  2026-11-08): every pass looks at what is in flight and what is coming,
  and sets the next one from that.

    * **Active** — a runner busy, a card in a doing list, a job queued or
      running, a wait open or a watch condition open: `min_minutes` (10
      unless the board says otherwise).
    * **Little** — nothing in flight, but cards on a ready list:
      `@little` minutes (30), kept within the bounds.
    * **Quiet** — nothing in flight and the ready lists empty:
      `max_minutes` (120 unless the board says otherwise).

  An event since the last pass (a rejection, a wait opened, a job ended)
  brings the next one forward to now, though never sooner than
  `@event_gap` minutes after the last pass. The watch checks run every
  minute regardless.
  """

  @little 30
  @event_gap 5

  @doc "The minutes before the next pass for `activity` (see `Slipdock.Overseer.Pass.activity/2`)."
  def next_minutes(activity, %{min_minutes: min, max_minutes: max}) do
    case level(activity) do
      :active -> min
      :little -> @little |> max(min) |> min(max)
      :quiet -> max
    end
  end

  @doc "How busy `activity` says the tree is: `:active`, `:little` or `:quiet`."
  def level(activity) do
    in_flight =
      Enum.any?(
        ~w(runners_busy cards_in_doing jobs_queued jobs_running waits_open conditions_open)a,
        &(Map.get(activity, &1, 0) > 0)
      )

    cond do
      in_flight -> :active
      Map.get(activity, :ready_cards, 0) > 0 -> :little
      true -> :quiet
    end
  end

  @doc """
  The next pass's time, `next`, brought forward when `event?`: to now, or
  `@event_gap` minutes after `last` if that is later. Never later than it was.
  """
  def forward(next, _last, _now, false), do: next

  def forward(next, last, now, true) do
    earliest = if last, do: later(now, DateTime.add(last, @event_gap * 60, :second)), else: now
    if next && DateTime.compare(next, earliest) != :gt, do: next, else: earliest
  end

  defp later(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  @doc "The minutes an event keeps after a pass before it can bring one forward."
  def event_gap, do: @event_gap
end

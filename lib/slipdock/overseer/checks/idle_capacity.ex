defmodule Slipdock.Overseer.Checks.IdleCapacity do
  @moduledoc """
  Idle capacity (#2068): cards free to take on a ready list (open, nobody
  on them, not flagged, nothing they wait on, no job) while runners on the
  tree are online and have had no job for the board's `idle_minutes`: the
  work and the hands are both there and nothing joins them.

  It clears when a runner takes work or the ready list empties.
  """
  @behaviour Slipdock.Overseer.Check

  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Overseer.Check
  alias Slipdock.Repo
  alias Slipdock.Runners
  alias Slipdock.Runners.{Job, Runner}

  @impl true
  def key, do: "idle_capacity"

  @impl true
  def label, do: "Idle capacity"

  @impl true
  def find(ctx), do: idle(ctx)

  defp idle(ctx) do
    with [_ | _] = runners <- idle_runners(ctx),
         [first | _] = cards <- free_cards(ctx) do
      names = Enum.map_join(runners, ", ", & &1.name)

      [
        %{
          subject: "ready",
          card_id: first.id,
          title:
            "#{length(cards)} ready #{plural(length(cards), "card")} and #{length(runners)} " <>
              "idle #{plural(length(runners), "runner")}",
          why:
            "#{Check.refs(cards)} #{if length(cards) == 1, do: "is", else: "are"} free on a " <>
              "ready list, and #{names} #{if length(runners) == 1, do: "has", else: "have"} " <>
              "had no job for #{ctx.settings.idle_minutes} minutes or more.",
          todo:
            "Nothing is sending the ready list to the runners: check the board's runner " <>
              "rule is on and its pool is the runners' pool, and that the board isn't paused."
        }
      ]
    else
      _ -> []
    end
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp idle_runners(%{root: root, settings: settings, now: now}) do
    cutoff = DateTime.add(now, -settings.idle_minutes * 60, :second)

    last_job =
      from(j in Job,
        where: not is_nil(j.runner_id),
        group_by: j.runner_id,
        select: %{runner_id: j.runner_id, at: max(coalesce(j.finished_at, j.updated_at))}
      )

    from(r in Runner,
      left_join: l in subquery(last_job),
      on: l.runner_id == r.id,
      where: r.board_id == ^root.id and is_nil(r.current_job_id) and is_nil(r.api_token_id),
      where: coalesce(l.at, r.inserted_at) <= ^cutoff,
      order_by: r.name
    )
    |> Repo.all()
    |> Enum.filter(&Runners.online?/1)
  end

  defp free_cards(ctx) do
    # A probe has no card (#2580); a NULL would empty `NOT IN`.
    open_jobs =
      from(j in Job,
        where: j.status in ^Job.open_statuses() and not is_nil(j.card_id),
        select: j.card_id
      )

    assigned = from(a in "card_assignees", select: a.card_id)

    ctx
    |> Check.live_cards()
    |> join(:inner, [c], col in Column, on: col.id == c.column_id and col.category == "todo")
    |> where([c], is_nil(c.assignee_id) and c.id not in subquery(assigned))
    |> where([c], not fragment("? && ?", c.flags, ^~w(blocked waiting review)))
    |> where([c], c.id not in subquery(open_jobs))
    |> order_by([c, col], asc: col.position, asc: c.position)
    |> Repo.all()
    |> Repo.preload(blocked_by: Boards.dependency_query())
    |> Enum.reject(&Card.blocked?/1)
  end
end

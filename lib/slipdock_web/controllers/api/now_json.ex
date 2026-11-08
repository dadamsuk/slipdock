defmodule SlipdockWeb.API.NowJSON do
  @moduledoc """
  Right now (#2103) as the REST API and MCP give it: `Slipdock.Now.snapshot/2`
  with the tree's root board's id, each field named here so a door never
  sends out more than this view lists.
  """

  @doc "`Slipdock.Now.snapshot/2` for the tree whose root is `root_id`, as JSON."
  def snapshot(root_id, %{runners: runners, in_progress: cards, queued: queued, counts: c}) do
    %{
      board_id: root_id,
      runners: Enum.map(runners, &runner/1),
      in_progress: Enum.map(cards, &card/1),
      queued: Enum.map(queued, &Map.put(job(&1), :held, &1.held)),
      counts: %{
        runners: c.runners,
        online: c.online,
        working: c.working,
        in_progress: c.in_progress,
        queued: c.queued
      }
    }
  end

  @doc "A runner and the jobs it holds."
  def runner(r) do
    %{
      id: r.id,
      name: r.name,
      pool: r.pool,
      online: r.online,
      session: r.session,
      jobs: Enum.map(r.jobs, &job/1)
    }
  end

  @doc "A card in progress and where it sits."
  def card(c) do
    %{
      id: c.id,
      title: c.title,
      board_id: c.board_id,
      board: c.board,
      list: c.list,
      parent: c.parent && Map.take(c.parent, [:id, :title, :board_id]),
      state: c.state,
      state_kind: c.state_kind,
      loop: c.loop && Map.take(c.loop, [:runner, :kind, :job_id]),
      holds: c.holds,
      age: c.age
    }
  end

  @doc "A job, held by a runner or queued."
  def job(j) do
    Map.take(j, [:id, :kind, :status, :pool, :card_id, :card, :board_id, :step, :step_at, :since])
  end
end

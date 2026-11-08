defmodule SlipdockWeb.API.OverseerJSON do
  @moduledoc """
  The overseer (#2068) as the API, MCP and the CLI give it: its settings,
  where it stands, and its conditions.
  """

  alias Slipdock.Overseer.{Condition, Watch}

  @doc "`Slipdock.Overseer.state/2` as JSON."
  def state(%{board: board, settings: s, conditions: open, cleared: cleared, open_job: job}) do
    %{
      board_id: board.id,
      enabled: s.enabled == true,
      pool: s.pool,
      min_minutes: s.min_minutes,
      max_minutes: s.max_minutes,
      idle_minutes: s.idle_minutes,
      email: s.email,
      card_id: s.card_id,
      next_run_at: s.next_run_at,
      last_run_at: s.last_queued_at,
      watched_at: s.watched_at,
      last_digest:
        s.last_digest && %{health: s.last_health, body: s.last_digest, at: s.last_digest_at},
      open_job: job && %{id: job.id, status: job.status, pool: job.pool},
      checks: Enum.map(Watch.checks(), &%{key: &1.key(), label: &1.label()}),
      conditions: Enum.map(open, &condition/1),
      cleared_last_day: Enum.map(cleared, &condition/1)
    }
  end

  @doc "One condition."
  def condition(%Condition{} = c) do
    %{
      id: c.id,
      check: c.check,
      subject: c.subject,
      card_id: c.card_id,
      severity: c.severity,
      title: c.title,
      why: c.why,
      todo: c.todo,
      opened_at: c.opened_at,
      cleared_at: c.cleared_at
    }
  end
end

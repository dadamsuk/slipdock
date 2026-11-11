defmodule Slipdock.Health.Detectors.IdleFeed do
  @moduledoc """
  A `list_top` rule that has sent nothing for `minutes` (default 15) — no
  open job, none ended or the rule changed in that time — while its list has
  a card it would send and a runner of its pool is online and idle. Not
  idle for a good reason: an empty list, a paused pool, the WIP limit, or a
  backfill feed (a Housekeeping list's, #2777) waiting its turn behind its
  pool's ready-list and Scheduled feeds (`Automations.yielding?/2`).

  The fix runs the feed (`Slipdock.Automations.feed/2`). If it sends a card,
  that is fixed; if it is still idle, the reason it gave goes in the log and
  the next run flags it (`max_attempts` 1).
  """
  @behaviour Slipdock.Health.Detector

  import Ecto.Query

  alias Slipdock.Automations
  alias Slipdock.Automations.{Rule, Spec}
  alias Slipdock.Boards.Card
  alias Slipdock.Health.{Context, Runs}
  alias Slipdock.Repo
  alias Slipdock.Runners
  alias Slipdock.Runners.Job

  @impl true
  def key, do: "idle_feed"
  @impl true
  def label, do: "Feed sitting idle"
  @impl true
  def defaults, do: %{"minutes" => 15, "max_attempts" => 1}

  @impl true
  def detect(%Context{} = ctx, %{"minutes" => minutes}) do
    root_id = ctx.board.id
    runners = Runs.runners(root_id)

    for rule <- feeds(ctx.board_ids),
        pools = pools(rule),
        not open_job?(rule),
        since = quiet_since(rule),
        Context.minutes_since(ctx, since) >= minutes,
        not Runners.paused?(root_id, pools),
        idle = Enum.filter(runners, &(Enum.member?(pools, &1.pool) and Runs.idle?(&1, ctx.now))),
        idle != [],
        %Card{} = card <- [Automations.next_card(rule, now: ctx.now)],
        not wip_held?(card),
        not Automations.yielding?(rule, now: ctx.now) do
      %{
        subject: %{"rule" => rule.id},
        card_id: nil,
        state: DateTime.to_iso8601(since),
        summary:
          "Rule “#{rule.name}” keeps the #{Enum.join(pools, ", ")} pool fed from " <>
            "#{rule.spec["trigger"]["column"]}, but has sent nothing for " <>
            "#{Context.minutes_since(ctx, since)} minutes, though ##{card.id} “#{card.title}” " <>
            "is ready and #{Enum.map_join(idle, ", ", & &1.name)} is idle.",
        data: %{"rule" => rule.id}
      }
    end
  end

  @impl true
  def resolve(%{data: %{"rule" => id}}, _attempt) do
    case Repo.get(Rule, id) do
      nil ->
        :no_fix

      rule ->
        case Automations.feed(rule) do
          {:ok, %Card{} = card} -> {:fixed, "ran the feed: it sent ##{card.id}"}
          {:ok, _} -> {:fixed, "ran the feed"}
          {:idle, reason} -> {:tried, "ran the feed; it is still idle (#{reason})"}
        end
    end
  end

  defp feeds(board_ids) do
    from(r in Rule, where: r.board_id in ^board_ids and r.enabled == true)
    |> Repo.all()
    |> Enum.filter(&Spec.feed?(&1.spec))
  end

  defp pools(rule) do
    rule.spec
    |> Spec.actions()
    |> Enum.filter(&(&1["type"] == "runner"))
    |> Enum.map(&(&1["pool"] |> to_string() |> String.downcase()))
  end

  defp open_job?(rule) do
    Repo.exists?(
      from(j in Job, where: j.rule_id == ^rule.id and j.status in ^Job.open_statuses())
    )
  end

  # When the rule last did anything: its last job ended, or it was saved.
  defp quiet_since(rule) do
    last =
      Repo.one(
        from(j in Job,
          where: j.rule_id == ^rule.id,
          select: max(coalesce(j.finished_at, j.updated_at))
        )
      )

    [rule.updated_at, last]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&utc/1)
    |> Enum.max(DateTime)
  end

  defp utc(%DateTime{} = at), do: at
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp wip_held?(%Card{} = card) do
    card = Repo.preload(card, :column)
    not Slipdock.Flow.doing_list?(card.column) and not is_nil(Runners.wip_full(card.board_id))
  end
end

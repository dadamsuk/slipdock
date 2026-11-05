defmodule Slipdock.Health.Detectors.OrphanInProgress do
  @moduledoc """
  A card in a doing list, last put there by an agent, with no open job and
  no activity for `minutes` (default 120), and not pending verification or
  merging: the job that had it ended and left it. The fix does what
  `Slipdock.Runners.Recovery` does — back to the top of its list (its last
  job's `list_top` list, else its board's ready list), with a comment —
  once; if it is back in progress and orphaned again, it is flagged.

  The gardener's `stale_in_progress` keeps the cards people drive and leaves
  these to the monitor.
  """
  @behaviour Slipdock.Health.Detector

  import Ecto.Query

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Automations.{Rule, Spec}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Health.{Cards, Context}
  alias Slipdock.Runners.Job

  @impl true
  def key, do: "orphan_in_progress"
  @impl true
  def label, do: "In progress, nobody on it"
  @impl true
  def defaults, do: %{"minutes" => 120, "max_attempts" => 1}

  @impl true
  def detect(%Context{} = ctx, %{"minutes" => minutes}) do
    doing = for {id, %{category: "doing"}} <- ctx.columns, do: id

    candidates =
      from(c in Card,
        as: :card,
        where:
          c.board_id in ^ctx.board_ids and c.column_id in ^doing and c.completed == false and
            is_nil(c.archived_at) and is_nil(c.stand_in_for_id) and
            coalesce(c.verify_state, "") not in ["pending", "merging"],
        where:
          not exists(
            from(j in Job,
              where: j.card_id == parent_as(:card).id and j.status in ^Job.open_statuses()
            )
          )
      )
      |> Repo.all()

    ids = Enum.map(candidates, & &1.id)
    agents = Cards.agent_driven(ids)
    last = Cards.last_activity(ids)

    for card <- candidates,
        MapSet.member?(agents, card.id),
        at = last[card.id],
        Context.minutes_since(ctx, at) >= minutes do
      %{
        subject: %{"card" => card.id},
        card_id: card.id,
        state: card.column_id,
        summary:
          "##{card.id} “#{card.title}” is in #{ctx.columns[card.column_id].name}, put there by an " <>
            "agent, with no job open on it and nothing done for " <>
            "#{div(Context.minutes_since(ctx, at), 60)} hours.",
        data: %{"card" => card.id}
      }
    end
  end

  @impl true
  def resolve(%{data: %{"card" => id}}, _attempt) do
    with %Card{archived_at: nil, completed: false} = card <- Repo.get(Card, id),
         {:ok, column} <- home(card) do
      Boards.add_comment(
        card,
        "**Health monitor:** this card sat in progress with no job on it and nothing " <>
          "happening. Moved back to the top of #{column.name}, so it is picked up again; " <>
          "the next job carries on from the comments and the working tree."
      )

      Boards.move_card_to_index(Repo.get!(Card, card.id), column, :top,
        actor: Slipdock.Actor.automation()
      )

      Boards.log_activity(
        card.board_id,
        card.id,
        "health",
        "put ##{card.id} back on #{column.name}"
      )

      {:fixed, "moved it back to the top of #{column.name}"}
    else
      _ -> :no_fix
    end
  end

  # Where it goes back to: the list its last job's list_top rule feeds, on
  # its own board, else the board's ready list.
  defp home(card) do
    board = Boards.get_board!(card.board_id)

    rule =
      Repo.one(
        from(j in Job,
          join: r in Rule,
          on: r.id == j.rule_id,
          where: j.card_id == ^card.id,
          order_by: [desc: j.id],
          limit: 1,
          select: r
        )
      )

    fed =
      with %Rule{board_id: board_id} = rule when board_id == board.id <- rule,
           true <- Spec.feed?(rule.spec),
           {:ok, column} <- Boards.find_column(board, to_string(rule.spec["trigger"]["column"])) do
        column
      else
        _ -> nil
      end

    case fed || ready(board) do
      nil -> :error
      column -> {:ok, column}
    end
  end

  defp ready(%Board{columns: columns}) when is_list(columns),
    do: Map.get(SlipdockWeb.APIGuide.list_roles(columns), :ready)

  defp ready(_), do: nil
end

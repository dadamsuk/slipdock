defmodule Slipdock.Health.Detectors.DeadBlocker do
  @moduledoc """
  An open card blocked by one that can never finish on its own: a blocker in
  a dropped list, or — on a board with a feed (`list_top` rules) — in a list
  no feed takes from and that isn't in progress or done (a *Maybe Later*),
  so nothing will ever send it. No fix (only a person can decide): the
  blocked card is flagged, naming the blocker. An archived blocker no longer
  blocks, so it isn't one.
  """
  @behaviour Slipdock.Health.Detector

  import Ecto.Query

  alias Slipdock.Automations.{Rule, Spec}
  alias Slipdock.Boards.Card
  alias Slipdock.Health.Context
  alias Slipdock.Repo

  @impl true
  def key, do: "dead_blocker"
  @impl true
  def label, do: "Blocked for good"
  @impl true
  def defaults, do: %{}

  @impl true
  def detect(%Context{} = ctx, _settings) do
    fed = fed_lists(ctx)
    feeding = fed |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    from(d in "card_dependencies",
      join: a in Card,
      on: a.id == d.blocked_id,
      join: b in Card,
      on: b.id == d.blocker_id,
      where:
        a.board_id in ^ctx.board_ids and a.completed == false and is_nil(a.archived_at) and
          b.completed == false and is_nil(b.archived_at),
      order_by: [a.id, b.id],
      select: {a, b}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {a, b} ->
      case why(ctx, b, fed, feeding) do
        nil ->
          []

        why ->
          [
            %{
              subject: %{"card" => a.id, "blocker" => b.id},
              card_id: a.id,
              state: {b.id, b.column_id},
              summary: "##{a.id} “#{a.title}” is blocked by ##{b.id} “#{b.title}”, which #{why}."
            }
          ]
      end
    end)
  end

  defp why(ctx, blocker, fed, feeding) do
    column =
      Map.get(ctx.columns, blocker.column_id) ||
        Repo.get(Slipdock.Boards.Column, blocker.column_id)

    cond do
      is_nil(column) ->
        nil

      column.category == "dropped" ->
        "is in #{column.name}, a dropped list"

      column.category == "done" or Slipdock.Flow.doing_list?(column) ->
        nil

      MapSet.member?(feeding, blocker.board_id) and {blocker.board_id, column.id} not in fed ->
        "is in #{column.name}, which no feed takes from, so nothing will send it"

      true ->
        nil
    end
  end

  # {board_id, column_id} for every list a list_top rule feeds on the tree.
  defp fed_lists(ctx) do
    from(r in Rule, where: r.board_id in ^ctx.board_ids and r.enabled == true)
    |> Repo.all()
    |> Enum.filter(&Spec.feed?(&1.spec))
    |> Enum.flat_map(fn rule ->
      name = rule.spec["trigger"]["column"] |> to_string() |> String.downcase()

      for {id, col} <- ctx.columns,
          col.board_id == rule.board_id,
          String.downcase(col.name) == name,
          do: {rule.board_id, id}
    end)
  end
end

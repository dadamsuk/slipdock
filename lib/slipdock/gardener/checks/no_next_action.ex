defmodule Slipdock.Gardener.Checks.NoNextAction do
  @moduledoc """
  An open epic with subcards but none of them open, and its work not all
  done (an empty sub-board, or only dropped subcards): flag it for review
  with a comment saying there is no next step (W-1807).
  """
  @behaviour Slipdock.Gardener.Check

  alias Slipdock.Gardener.Checks.Cards
  alias Slipdock.Gardener.Context
  alias Slipdock.Rollup

  @impl true
  def key, do: "no_next_action"
  @impl true
  def label, do: "Epics with no next step"
  @impl true
  def defaults, do: %{"enabled" => true}

  @impl true
  def find(ctx, _settings) do
    for card <- Cards.cards(ctx),
        not card.completed,
        "review" not in card.flags,
        Context.category(ctx, card) not in ["done", "dropped"],
        sub = Cards.sub_board(ctx, card),
        not all_done?(card),
        not Enum.any?(Rollup.board_cards(ctx.rollup, sub), &open?(ctx, &1)) do
      %{
        subject: %{"cards" => [card.id]},
        state: card.updated_at,
        proposal: [
          %{"op" => "flag", "card" => card.id, "flag" => "review"},
          %{
            "op" => "comment",
            "card" => card.id,
            "body" => "No next step: none of its subcards is open."
          }
        ],
        explanation:
          "“#{card.title}” has subcards but none of them is open, and its work isn't all done"
      }
    end
  end

  defp all_done?(%{rollup: %{total: total, done: done}}), do: total > 0 and done == total

  defp open?(ctx, sub), do: not sub.completed and Context.category(ctx, sub) != "dropped"
end

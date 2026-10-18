defmodule Slipdock.Gardener.Checks.EpicDone do
  @moduledoc "An open epic whose work is all done: complete it and move it to done (W-1807)."
  @behaviour Slipdock.Gardener.Check

  alias Slipdock.Gardener.Checks.Cards
  alias Slipdock.Gardener.Context

  @impl true
  def key, do: "epic_done"
  @impl true
  def label, do: "Epics whose work is all done"
  @impl true
  def defaults, do: %{"enabled" => true}

  @impl true
  def find(ctx, _settings) do
    for card <- Cards.cards(ctx),
        not card.completed,
        Cards.sub_board(ctx, card),
        Context.category(ctx, card) != "dropped",
        stats = card.rollup,
        stats.total > 0 and stats.done == stats.total do
      done = Context.role_column(ctx, card.board_id, :done)

      move =
        if done && done.id != card.column_id,
          do: [%{"op" => "move", "card" => card.id, "column" => done.id}],
          else: []

      %{
        subject: %{"cards" => [card.id]},
        state: {card.updated_at, stats.total},
        proposal: [%{"op" => "complete", "card" => card.id}] ++ move,
        explanation:
          "“#{card.title}” has all #{stats.total} of its subcards done but is still open" <>
            if(move != [], do: " in #{Cards.list_name(ctx, card)}", else: "")
      }
    end
  end
end

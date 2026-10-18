defmodule Slipdock.Gardener.Checks.CompletedNotDone do
  @moduledoc "A completed card sitting outside a done list: move it there (W-1807)."
  @behaviour Slipdock.Gardener.Check

  alias Slipdock.Gardener.Checks.Cards
  alias Slipdock.Gardener.Context

  @impl true
  def key, do: "completed_not_done"
  @impl true
  def label, do: "Complete but not in Done"
  @impl true
  def defaults, do: %{"enabled" => true}

  @impl true
  def find(ctx, _settings) do
    for card <- Cards.cards(ctx),
        card.completed,
        Context.category(ctx, card) not in ["done", "dropped"],
        done = Context.role_column(ctx, card.board_id, :done),
        done != nil and done.id != card.column_id do
      %{
        subject: %{"cards" => [card.id]},
        state: {card.updated_at, card.column_id},
        proposal: [%{"op" => "move", "card" => card.id, "column" => done.id}],
        explanation:
          "“#{card.title}” is complete but still in #{Cards.list_name(ctx, card)}, not “#{done.name}”"
      }
    end
  end
end

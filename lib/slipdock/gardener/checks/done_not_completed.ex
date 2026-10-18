defmodule Slipdock.Gardener.Checks.DoneNotCompleted do
  @moduledoc "A card in a done list that was never marked complete (W-1807)."
  @behaviour Slipdock.Gardener.Check

  alias Slipdock.Gardener.Checks.Cards
  alias Slipdock.Gardener.Context

  @impl true
  def key, do: "done_not_completed"
  @impl true
  def label, do: "In Done but not complete"
  @impl true
  def defaults, do: %{"enabled" => true}

  @impl true
  def find(ctx, _settings) do
    for card <- Cards.cards(ctx),
        not card.completed,
        Context.category(ctx, card) == "done",
        # An epic with work still open beneath it isn't done, whatever list
        # it is in; completing it would be the wrong fix.
        not open_beneath?(ctx, card) do
      %{
        subject: %{"cards" => [card.id]},
        state: card.updated_at,
        proposal: [%{"op" => "complete", "card" => card.id}],
        explanation:
          "“#{card.title}” is in #{Cards.list_name(ctx, card)} but was never marked complete"
      }
    end
  end

  defp open_beneath?(ctx, card) do
    Cards.sub_board(ctx, card) != nil and card.rollup.done < card.rollup.total
  end
end

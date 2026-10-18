defmodule Slipdock.Gardener.Checks.AbandonedBacklog do
  @moduledoc """
  A card waiting in a to-do or backlog list, untouched for `days` (default
  180): archive it — it can be restored (W-1807). Off unless a board turns
  it on.
  """
  @behaviour Slipdock.Gardener.Check

  alias Slipdock.Gardener.Checks.Cards
  alias Slipdock.Gardener.Context

  @impl true
  def key, do: "abandoned_backlog"
  @impl true
  def label, do: "Abandoned in the backlog"
  @impl true
  def defaults, do: %{"enabled" => false, "days" => 180}

  @impl true
  def find(ctx, %{"days" => days}) do
    candidates =
      Enum.filter(Cards.cards(ctx), &(not &1.completed and Context.category(ctx, &1) == "todo"))

    last = Cards.last_activity(candidates)

    for card <- candidates,
        # Work hanging beneath an epic is its own activity.
        is_nil(Cards.sub_board(ctx, card)),
        {at, _} = last[card.id],
        Cards.days_since(at, ctx.now) >= days do
      %{
        subject: %{"cards" => [card.id]},
        state: at,
        proposal: [%{"op" => "archive", "card" => card.id}],
        explanation:
          "“#{card.title}” has waited in #{Cards.list_name(ctx, card)} untouched since #{Cards.day(at)}"
      }
    end
  end
end

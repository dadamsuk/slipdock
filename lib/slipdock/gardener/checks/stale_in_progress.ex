defmodule Slipdock.Gardener.Checks.StaleInProgress do
  @moduledoc """
  A card in a doing list nobody has touched for `days` (default 14): move
  it back to the ready list, or snooze it, or ask on it (W-1807).
  """
  @behaviour Slipdock.Gardener.Check

  alias Slipdock.Gardener.Checks.Cards
  alias Slipdock.Gardener.Context

  @impl true
  def key, do: "stale_in_progress"
  @impl true
  def label, do: "In progress, untouched"
  @impl true
  def defaults, do: %{"enabled" => true, "days" => 14}

  @impl true
  def find(ctx, %{"days" => days}) do
    candidates =
      Enum.filter(Cards.cards(ctx), &(not &1.completed and Context.category(ctx, &1) == "doing"))

    last = Cards.last_activity(candidates)

    for card <- candidates,
        {at, commenter} = last[card.id],
        Cards.days_since(at, ctx.now) >= days do
      ready = Context.role_column(ctx, card.board_id, :ready)
      snooze_until = ctx.today |> Date.add(7) |> Date.to_iso8601()

      ask = [
        %{
          "op" => "comment",
          "card" => card.id,
          "body" =>
            "Is this still being worked on? Nothing has happened on it since #{Cards.day(at)}."
        }
      ]

      snooze = [%{"op" => "snooze", "card" => card.id, "until" => snooze_until}]

      {proposal, alternatives} =
        if ready,
          do:
            {[%{"op" => "move", "card" => card.id, "column" => ready.id}],
             %{"snooze" => snooze, "ask" => ask}},
          else: {ask, %{"snooze" => snooze}}

      %{
        subject: %{"cards" => [card.id]},
        state: at,
        proposal: proposal,
        alternatives: alternatives,
        explanation:
          "“#{card.title}” is in #{Cards.list_name(ctx, card)} with no activity since #{Cards.day(at)}" <>
            if(commenter, do: "; last comment by #{commenter}", else: "")
      }
    end
  end
end

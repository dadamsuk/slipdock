defmodule Slipdock.Gardener.Checks.LongOverdue do
  @moduledoc """
  An open card due more than `days` ago (default 30): give it a new date a
  week out, or snooze it, or archive it (W-1807).
  """
  @behaviour Slipdock.Gardener.Check

  alias Slipdock.Gardener.Checks.Cards
  alias Slipdock.Gardener.Context

  @impl true
  def key, do: "long_overdue"
  @impl true
  def label, do: "Long overdue"
  @impl true
  def defaults, do: %{"enabled" => true, "days" => 30}

  @impl true
  def find(ctx, %{"days" => days}) do
    for card <- Cards.cards(ctx),
        not card.completed,
        card.due_date,
        Context.category(ctx, card) not in ["done", "dropped"],
        late = Date.diff(ctx.today, card.due_date),
        late > days do
      week = ctx.today |> Date.add(7) |> Date.to_iso8601()

      %{
        subject: %{"cards" => [card.id]},
        state: card.due_date,
        proposal: [%{"op" => "redate", "card" => card.id, "due" => week}],
        alternatives: %{
          "snooze" => [%{"op" => "snooze", "card" => card.id, "until" => week}],
          "archive" => [%{"op" => "archive", "card" => card.id}]
        },
        explanation:
          "“#{card.title}” was due #{Cards.day(card.due_date)}, #{late} days ago, and is still open"
      }
    end
  end
end

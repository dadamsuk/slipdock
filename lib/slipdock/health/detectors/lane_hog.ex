defmodule Slipdock.Health.Detectors.LaneHog do
  @moduledoc """
  A card in progress whose lane has kept another card's job waiting for
  over `hours` (default 4) while nothing happened on it. No fix: the card
  holding the lane is flagged, naming the card it holds up.
  """
  @behaviour Slipdock.Health.Detector

  import Ecto.Query

  alias Slipdock.{Lanes, Repo}
  alias Slipdock.Health.{Cards, Context}
  alias Slipdock.Runners.Job

  @impl true
  def key, do: "lane_hog"
  @impl true
  def label, do: "Lane held, nothing moving"
  @impl true
  def defaults, do: %{"hours" => 4}

  @impl true
  def detect(%Context{} = ctx, %{"hours" => hours}) do
    held = Lanes.held_cards(ctx.board.id)
    minutes = hours * 60

    jobs =
      from(j in Job,
        where:
          j.root_board_id == ^ctx.board.id and j.status == "queued" and
            j.card_id in ^Map.keys(held),
        order_by: j.id
      )
      |> Repo.all()
      |> Enum.uniq_by(& &1.card_id)

    last = Cards.last_activity(held |> Map.values() |> Enum.map(& &1.id))

    for job <- jobs,
        holder = held[job.card_id],
        Context.minutes_since(ctx, job.inserted_at) >= minutes,
        at = last[holder.id],
        Context.minutes_since(ctx, at) >= minutes do
      %{
        subject: %{"card" => holder.id, "held" => job.card_id},
        card_id: holder.id,
        state: {job.id, DateTime.to_iso8601(at)},
        summary:
          "##{holder.id} “#{holder.title}” holds the lane that has kept job ##{job.id} on " <>
            "##{job.card_id} waiting #{div(Context.minutes_since(ctx, job.inserted_at), 60)} hours, " <>
            "and nothing has happened on it for #{div(Context.minutes_since(ctx, at), 60)} hours."
      }
    end
  end
end

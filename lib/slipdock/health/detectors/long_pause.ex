defmodule Slipdock.Health.Detectors.LongPause do
  @moduledoc """
  A runner pool, or a whole tree, paused for over `hours` (default 12):
  somebody may have forgotten to resume it. No fix (only a person resumes):
  it is flagged with a board alert.
  """
  @behaviour Slipdock.Health.Detector

  alias Slipdock.Health.Context
  alias Slipdock.Runners
  alias Slipdock.Runners.Pause

  @impl true
  def key, do: "long_pause"
  @impl true
  def label, do: "Paused for hours"
  @impl true
  def defaults, do: %{"hours" => 12}

  @impl true
  def detect(%Context{} = ctx, %{"hours" => hours}) do
    for pause <- Runners.open_pauses(ctx.board.id),
        (minutes = Context.minutes_since(ctx, pause.inserted_at)) >= hours * 60 do
      %{
        subject: %{"pause" => pause.id},
        card_id: nil,
        state: pause.id,
        summary:
          "#{String.capitalize(Pause.scope(pause))} has been paused for #{div(minutes, 60)} hours " <>
            "(#{Pause.line(pause)}). No job in it is handed out until a person resumes it."
      }
    end
  end
end

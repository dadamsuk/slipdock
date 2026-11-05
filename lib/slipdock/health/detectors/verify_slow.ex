defmodule Slipdock.Health.Detectors.VerifySlow do
  @moduledoc """
  A verify job claimed for over `minutes` (default 60) with no progress step
  or note: like `hung_job`, which leaves verify jobs to this, but named for
  the work it holds up — the card waits for its verdict. No fix: flagged.
  """
  @behaviour Slipdock.Health.Detector

  alias Slipdock.Health.Context
  alias Slipdock.Health.Detectors.HungJob
  alias Slipdock.Verified

  @impl true
  def key, do: "verify_slow"
  @impl true
  def label, do: "Verify job with no progress"
  @impl true
  def defaults, do: %{"minutes" => 60}

  @impl true
  def detect(%Context{} = ctx, settings) do
    ctx
    |> HungJob.find(settings, [Verified.verify_kind()], "verify job")
    |> Enum.map(fn f ->
      %{f | summary: f.summary <> " ##{f.card_id} waits for its verdict."}
    end)
  end
end

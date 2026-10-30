defmodule Slipdock.OCR.Worker do
  @moduledoc """
  Works through the queue in `Slipdock.OCR`, one file at a time, for as long
  as there is one to read. Nothing depends on it: an upload casts `nudge/0`
  and goes on, and the scheduler nudges it every minute anyway.

  Tests set `config :slipdock, :ocr, worker: false` and call
  `Slipdock.OCR.run_next/0` themselves.
  """

  use GenServer

  require Logger

  alias Slipdock.OCR

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Wakes the worker. Never blocks and never fails."
  def nudge do
    if Slipdock.Config.get(:ocr, [])[:worker] != false, do: GenServer.cast(__MODULE__, :work)
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{warned: false}}

  @impl true
  def handle_cast(:work, state) do
    case safely_run_next() do
      :ok ->
        GenServer.cast(self(), :work)
        {:noreply, state}

      :unavailable when not state.warned ->
        Logger.warning(
          "Uploaded PDFs and images can't be read for text: tesseract and poppler aren't installed"
        )

        {:noreply, %{state | warned: true}}

      _ ->
        {:noreply, state}
    end
  end

  # The scheduler's next nudge tries again.
  defp safely_run_next do
    OCR.run_next()
  rescue
    exception ->
      Logger.error("Reading a document failed: #{Exception.message(exception)}")
      :none
  end
end

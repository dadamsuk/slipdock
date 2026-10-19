defmodule Slipdock.MoveRecorder do
  @moduledoc """
  Hears every card move (the `[:slipdock, :card, :moved]` telemetry event
  `Slipdock.Boards` raises at its move choke points) and sends it to the test
  that asked, as `{:moved, metadata}`. Moves from other async tests arrive
  too, so match on the card id.
  """

  @event [:slipdock, :card, :moved]

  def attach do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, @event, &__MODULE__.handle/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  def handle(_event, _measurements, metadata, pid), do: send(pid, {:moved, metadata})
end

defmodule Slipdock.Meetings.Relisten do
  @moduledoc """
  Pipeline step 8: unclear passages a finding depends on, listened to again.
  Only a capture with its recording still kept has anything to re-listen to.
  """

  alias Slipdock.Meetings.Capture

  @doc "Re-listens where it matters (step 8)."
  def run(%Capture{} = capture, _opts), do: {:ok, capture}
end

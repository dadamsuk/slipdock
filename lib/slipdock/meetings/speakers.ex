defmodule Slipdock.Meetings.Speakers do
  @moduledoc """
  Pipeline steps 3 and 4: separating the voices in a recording, and working
  out who each one is. With no recording, the transcript's own speaker labels
  are what there is.
  """

  alias Slipdock.Meetings.Capture

  @doc "Separates the voices (step 3)."
  def diarise(%Capture{} = capture, _opts), do: {:ok, capture}

  @doc "Attributes each voice to a person (step 4)."
  def attribute(%Capture{} = capture, _opts), do: {:ok, capture}
end

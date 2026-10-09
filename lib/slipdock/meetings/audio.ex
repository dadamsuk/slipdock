defmodule Slipdock.Meetings.Audio do
  @moduledoc """
  Pipeline step 2: turning a recording into transcript lines, or lining a
  supplied transcript up with the recording. A capture with a transcript
  and no recording has nothing to do here.
  """

  alias Slipdock.Meetings.Capture

  @doc "`{:ok, capture}` once the capture has lines to read, or `{:error, reason}`."
  def transcribe(%Capture{transcript: transcript} = capture, _opts) when is_binary(transcript),
    do: {:ok, capture}

  def transcribe(%Capture{audio_key: key}, _opts) when is_binary(key),
    do:
      {:error,
       "this server transcribes nothing yet, so a recording needs a transcript sent with it"}

  def transcribe(%Capture{}, _opts), do: {:error, "there is no transcript or recording to read"}
end

defmodule Slipdock.Meetings.Limits do
  @moduledoc """
  How big a meeting this server takes: the largest transcript, recording and
  findings file, and the longest meeting. Each is checked at ingest, before
  anything is stored or sent anywhere. The recording size and the longest
  meeting are the admin's (Configuration › Meetings); what one person may use
  in a month is `Slipdock.Meetings.Usage`'s.
  """

  @audio_extensions ~w(.wav .mp3 .m4a .mp4 .flac .ogg .oga .opus .webm .aac .mpeg .mpga)

  @doc "The largest transcript accepted, in bytes."
  def max_transcript_bytes, do: config(:max_transcript_bytes, 10 * 1024 * 1024)

  @doc "The largest findings file accepted, in bytes."
  def max_findings_bytes, do: config(:max_findings_bytes, 2 * 1024 * 1024)

  @doc "The largest recording accepted, in bytes: the admin's setting (Configuration › Meetings)."
  def max_audio_bytes,
    do:
      config(
        :max_audio_bytes,
        (Slipdock.Settings.get().meetings_max_file_mb || 500) * 1024 * 1024
      )

  @doc "The longest meeting read, in minutes: the admin's setting."
  def longest_meeting_minutes,
    do: config(:longest_meeting_minutes, Slipdock.Settings.get().meetings_longest_minutes || 240)

  @doc "The recording extensions accepted: what the transcription providers take."
  def audio_extensions, do: @audio_extensions

  @doc "Whether an upload looks like audio this server takes, by its name or its type."
  def audio_type?(audio) do
    ext = (audio[:filename] || "") |> Path.extname() |> String.downcase()
    type = audio[:content_type] || ""

    ext in @audio_extensions or String.starts_with?(type, "audio/")
  end

  defp config(key, default),
    do: Keyword.get(Slipdock.Config.get(:meetings, []), key, default)
end

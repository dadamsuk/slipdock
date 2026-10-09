defmodule Slipdock.Meetings.Utterance do
  @moduledoc """
  One line of a capture's transcript: who said it (the transcript's own label,
  and the voice it was attributed to), when, and exactly what. The text is the
  transcript's, word for word; nothing edits it. `words` keeps per-word
  timings and confidence where the transcriber gave them.
  """
  use Ecto.Schema

  schema "capture_utterances" do
    belongs_to :capture, Slipdock.Meetings.Capture
    field :position, :integer
    field :line_id, :string
    field :start_ms, :integer
    field :end_ms, :integer
    field :speaker, :string
    belongs_to :voice, Slipdock.Meetings.Voice
    field :voice_unsure, :boolean, default: false
    field :text, :string
    field :words, {:array, :map}
  end
end

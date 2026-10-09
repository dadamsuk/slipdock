defmodule Slipdock.Meetings.Evidence do
  @moduledoc """
  The words a finding came from: a span of one transcript line (`line_id`,
  `char_start`..`char_end`) and the `quote` itself, which code has checked is
  in the transcript word for word (G2). The speaker and time are copied in, so
  the trail still reads true after the transcript and audio are gone (G11).
  """
  use Ecto.Schema

  schema "capture_evidence" do
    belongs_to :finding, Slipdock.Meetings.Finding
    belongs_to :utterance, Slipdock.Meetings.Utterance
    field :line_id, :string
    field :char_start, :integer
    field :char_end, :integer
    field :quote, :string
    field :speaker, :string
    field :start_ms, :integer
  end
end

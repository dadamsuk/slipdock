defmodule Slipdock.Runners.TranscriptChunk do
  @moduledoc """
  One send of a job's transcript (#1870): whole lines of its agent's Claude
  Code transcript, as the runner sent them, cut and scrubbed (see
  `Slipdock.Runners.Transcript`).
  """
  use Ecto.Schema

  schema "runner_job_transcript_chunks" do
    field :first_line, :integer
    field :lines, :integer
    field :bytes, :integer
    field :body, :string

    belongs_to :job, Slipdock.Runners.Job

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

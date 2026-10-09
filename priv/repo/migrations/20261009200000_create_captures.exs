defmodule Slipdock.Repo.Migrations.CreateCaptures do
  use Ecto.Migration

  def change do
    # A meeting sent to a board: its transcript and/or audio, where the
    # pipeline has got to, and — once committed — the change set it wrote.
    create table(:captures) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :started_at, :utc_datetime
      add :attendees, {:array, :map}, null: false, default: []
      add :state, :string, null: false, default: "receiving"
      add :state_reason, :text
      # The pipeline step last finished, so a restart resumes after it.
      add :step, :string
      add :progress, :map, null: false, default: %{}
      add :fingerprint, :string, null: false
      add :source, :string, null: false, default: "upload"
      add :sources, :map, null: false, default: %{}
      add :context_scope, :map, null: false, default: %{}
      add :retention, :string, null: false, default: "30_days"
      add :stats, :map, null: false, default: %{}
      # The transcript exactly as received: evidence, never edited.
      add :transcript, :text
      add :transcript_format, :string
      add :audio_key, :string
      add :audio_filename, :string
      add :audio_content_type, :string
      add :audio_size, :bigint
      add :audio_duration_ms, :integer
      add :audio_purged_at, :utc_datetime
      add :change_set, :map
      add :committed_at, :utc_datetime
      add :committed_by_id, references(:users, on_delete: :nilify_all)
      add :discarded_at, :utc_datetime
      add :discarded_by_id, references(:users, on_delete: :nilify_all)
      add :undone_at, :utc_datetime
      add :undone_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:captures, [:board_id, :inserted_at])
    create index(:captures, [:owner_id])
    create index(:captures, [:state])
    # One capture per meeting per board (G10): sending the same transcript or
    # recording again finds the first.
    create unique_index(:captures, [:board_id, :fingerprint])

    # Who was speaking: a voice from diarisation, or a label from the
    # transcript, and who it is believed to be.
    create table(:capture_voices) do
      add :capture_id, references(:captures, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :name, :string
      add :user_id, references(:users, on_delete: :nilify_all)
      add :evidence, {:array, :map}, null: false, default: []
      add :confirmed_by_id, references(:users, on_delete: :nilify_all)
      add :confirmed_at, :utc_datetime
      add :merged_into_id, references(:capture_voices, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:capture_voices, [:capture_id])

    # One line of the transcript, word for word.
    create table(:capture_utterances) do
      add :capture_id, references(:captures, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :line_id, :string, null: false
      add :start_ms, :integer
      add :end_ms, :integer
      add :speaker, :string
      add :voice_id, references(:capture_voices, on_delete: :nilify_all)
      add :voice_unsure, :boolean, null: false, default: false
      add :text, :text, null: false
      add :words, {:array, :map}
    end

    create unique_index(:capture_utterances, [:capture_id, :position])
    create unique_index(:capture_utterances, [:capture_id, :line_id])

    # What the meeting is proposed to have produced.
    create table(:capture_findings) do
      add :capture_id, references(:captures, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0
      add :kind, :string, null: false
      add :title, :string, null: false
      add :body, :text
      add :effect, :map, null: false, default: %{}
      add :included, :boolean, null: false, default: true
      add :status, :string, null: false, default: "kept"
      add :drop_reason, :text
      add :origin, :string, null: false, default: "reading"
      add :readings, {:array, :integer}, null: false, default: []
      add :signals, {:array, :string}, null: false, default: []
      add :links, {:array, :map}, null: false, default: []
      add :known, {:array, :map}, null: false, default: []
      add :edited_by_id, references(:users, on_delete: :nilify_all)
      add :edited_at, :utc_datetime
      add :added_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:capture_findings, [:capture_id, :position])

    # The words a finding came from: a span of one line, quoted exactly.
    create table(:capture_evidence) do
      add :finding_id, references(:capture_findings, on_delete: :delete_all), null: false
      add :utterance_id, references(:capture_utterances, on_delete: :nilify_all)
      add :line_id, :string
      add :char_start, :integer
      add :char_end, :integer
      add :quote, :text, null: false
      add :speaker, :string
      add :start_ms, :integer
    end

    create index(:capture_evidence, [:finding_id])

    # Something a person has to settle before the capture can be committed,
    # and — on the same row — how it was settled: who, when, what, and after
    # what (a replayed span, a question put to the speaker).
    create table(:capture_questions) do
      add :capture_id, references(:captures, on_delete: :delete_all), null: false
      add :finding_id, references(:capture_findings, on_delete: :delete_all)
      add :kind, :string, null: false
      add :prompt, :text, null: false
      add :options, {:array, :map}, null: false, default: []
      add :blocking, :boolean, null: false, default: true
      add :status, :string, null: false, default: "open"
      add :answer, :map
      add :answered_by_id, references(:users, on_delete: :nilify_all)
      add :answered_at, :utc_datetime
      add :via, :string
      add :context, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create index(:capture_questions, [:capture_id, :status])

    # The capture's record: received, read, each resolution, commit, undo.
    create table(:capture_events) do
      add :capture_id, references(:captures, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :message, :text, null: false
      add :via, :string
      add :data, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:capture_events, [:capture_id, :inserted_at])

    # What meeting capture has cost, line by line: transcription seconds,
    # model tokens, stored bytes — against a person, a capture and a month.
    create table(:meeting_usage) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :capture_id, references(:captures, on_delete: :nilify_all)
      add :board_id, references(:boards, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :step, :string
      add :seconds, :float
      add :tokens_in, :integer
      add :tokens_out, :integer
      add :bytes, :bigint
      add :cost, :float
      add :own_key, :boolean, null: false, default: false
      add :model, :string
      add :month, :date, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:meeting_usage, [:user_id, :month])
    create index(:meeting_usage, [:month])
    create index(:meeting_usage, [:capture_id])
  end
end

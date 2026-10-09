defmodule Slipdock.Meetings.Capture do
  @moduledoc """
  One meeting sent to one board: its transcript and/or audio, where the
  pipeline has got to with it, and what it proposed and wrote.

  ## States

      receiving → reading → needs_review ⇄ ready → committed
                     ↘          ↘          ↘
                      failed     discarded   discarded

  * `receiving` — the files are arriving and being checked.
  * `reading` — the pipeline is working on it (see `step` for where).
  * `needs_review` — read, with questions a person has to answer.
  * `ready` — nothing left to answer: it can be committed.
  * `committed` — written to the board, once (G10). Undoing it stamps
    `undone_at` and leaves it committed, so it can never be written twice.
  * `discarded` — somebody decided not to; the record stays.
  * `failed` — a step failed, with the reason in `state_reason`. Retrying
    puts it back to `reading`, from the step after the last one finished.

  `transition/3` is the only way the state moves, and refuses anything not
  drawn above.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(receiving reading needs_review ready committed discarded failed)
  @sources ~w(upload agent connector)
  @retentions ~w(until_committed 30_days 90_days)

  # Where each state may go next.
  @moves %{
    "receiving" => ~w(reading failed discarded),
    "reading" => ~w(needs_review ready failed discarded),
    "needs_review" => ~w(ready discarded reading),
    "ready" => ~w(needs_review committed discarded reading),
    "failed" => ~w(reading discarded),
    "committed" => [],
    "discarded" => []
  }

  schema "captures" do
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :owner, Slipdock.Accounts.User
    field :title, :string
    field :started_at, :utc_datetime
    field :attendees, {:array, :map}, default: []
    field :state, :string, default: "receiving"
    field :state_reason, :string
    field :step, :string
    field :progress, :map, default: %{}
    field :fingerprint, :string
    field :source, :string, default: "upload"
    field :sources, :map, default: %{}
    field :context_scope, :map, default: %{}
    field :retention, :string, default: "30_days"
    field :stats, :map, default: %{}
    field :transcript, :string
    field :transcript_format, :string
    field :audio_key, :string
    field :audio_filename, :string
    field :audio_content_type, :string
    field :audio_size, :integer
    field :audio_duration_ms, :integer
    field :audio_purged_at, :utc_datetime
    field :change_set, :map
    field :committed_at, :utc_datetime
    belongs_to :committed_by, Slipdock.Accounts.User
    field :discarded_at, :utc_datetime
    belongs_to :discarded_by, Slipdock.Accounts.User
    field :undone_at, :utc_datetime
    belongs_to :undone_by, Slipdock.Accounts.User

    has_many :utterances, Slipdock.Meetings.Utterance, preload_order: [asc: :position]
    has_many :voices, Slipdock.Meetings.Voice
    has_many :findings, Slipdock.Meetings.Finding, preload_order: [asc: :position, asc: :id]
    has_many :questions, Slipdock.Meetings.Question, preload_order: [asc: :id]
    has_many :events, Slipdock.Meetings.Event, preload_order: [asc: :inserted_at, asc: :id]

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def sources, do: @sources
  def retentions, do: @retentions

  @doc "The states a capture in `state` may move to."
  def moves(state), do: Map.get(@moves, state, [])

  @doc "Whether the pipeline is still working on it."
  def active?(%__MODULE__{state: state}), do: state in ~w(receiving reading)

  @doc "Whether it is finished with: written, or decided against."
  def closed?(%__MODULE__{state: state}), do: state in ~w(committed discarded)

  @doc "A new capture: what was sent, and about which meeting."
  def create_changeset(capture, attrs) do
    capture
    |> cast(attrs, [
      :title,
      :started_at,
      :attendees,
      :fingerprint,
      :source,
      :sources,
      :context_scope,
      :retention,
      :transcript,
      :transcript_format
    ])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title, :fingerprint])
    |> validate_length(:title, max: 200)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:retention, @retentions)
    |> unique_constraint([:board_id, :fingerprint])
  end

  @doc "What a reviewer may change about the meeting itself."
  def details_changeset(capture, attrs) do
    capture
    |> cast(attrs, [:title, :started_at, :attendees])
    |> validate_required([:title])
    |> validate_length(:title, max: 200)
  end

  @doc """
  Moves the state on, or refuses: `{:error, changeset}` with an error on
  `:state` naming both ends when the move is not one of the drawn ones.
  """
  def transition(capture, to, extra \\ %{}) do
    changeset = change(capture, Map.put(extra, :state, to))

    if to in moves(capture.state) do
      changeset
    else
      add_error(changeset, :state, "cannot go from #{capture.state} to #{to}")
    end
  end
end

defmodule Slipdock.Meetings.Finding do
  @moduledoc """
  Something a capture proposes the meeting produced: a decision, an action, a
  change to a card, an open question or an idea.

  * `effect` — what committing it would do (a new card and where, a change to
    which card, an entry on which decisions page), as data the change set is
    built from.
  * `evidence` — the transcript spans it came from, quoted exactly.
  * `signals` — labels a reader can check (`quoted`, `both_readings`, …),
    never a percentage.
  * `links` — existing cards and pages it is about, each with how strongly
    and the version it was read at (for the stale check, G7).
  * `known` — what Slipdock already knew that bears on it.
  * `status` — `kept`, or `dropped` with a `drop_reason` (G2: a quote the
    transcript does not contain). Dropped findings stay, so the drop shows.
  * `origin` — `reading` (the model), `agent` (sent with the capture) or
    `person` (added in review, with no evidence).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(decision action card_change open_question idea)
  @origins ~w(reading agent person)

  schema "capture_findings" do
    belongs_to :capture, Slipdock.Meetings.Capture
    field :position, :integer, default: 0
    field :kind, :string
    field :title, :string
    field :body, :string
    field :effect, :map, default: %{}
    field :included, :boolean, default: true
    field :status, :string, default: "kept"
    field :drop_reason, :string
    field :origin, :string, default: "reading"
    field :readings, {:array, :integer}, default: []
    field :signals, {:array, :string}, default: []
    field :links, {:array, :map}, default: []
    field :known, {:array, :map}, default: []
    belongs_to :edited_by, Slipdock.Accounts.User
    field :edited_at, :utc_datetime
    belongs_to :added_by, Slipdock.Accounts.User
    has_many :evidence, Slipdock.Meetings.Evidence, preload_order: [asc: :id]
    has_many :questions, Slipdock.Meetings.Question
    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def origins, do: @origins

  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [
      :position,
      :kind,
      :title,
      :body,
      :effect,
      :included,
      :status,
      :drop_reason,
      :origin,
      :readings,
      :signals,
      :links,
      :known
    ])
    |> validate_required([:kind, :title])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:origin, @origins)
    |> validate_inclusion(:status, ~w(kept dropped))
    |> validate_length(:title, max: 255)
  end

  @doc "A reviewer's edit: what it says and what it does, never its evidence."
  def edit_changeset(finding, attrs) do
    finding
    |> cast(attrs, [:title, :body, :effect, :kind])
    |> validate_required([:kind, :title])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:title, max: 255)
  end
end

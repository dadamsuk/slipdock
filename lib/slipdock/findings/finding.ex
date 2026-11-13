defmodule Slipdock.Findings.Finding do
  @moduledoc """
  One thing a pass learned, or the system saw go wrong (see `Slipdock.Findings`).

    * `board` – the root board of the tree it was found in
    * `card`, `comment`, `job` – where it came from, whichever apply
    * `kind` – `gotcha`, `rule` (a rule candidate), `handbook-wrong`, `tooling`
      or `process`
    * `source` – who noticed: `agent` (a `Findings:` block in a comment), or the
      system's own signals: `rejection`, `verification` (a rule hit on code
      the change didn't touch, #1945), `requeue`, `timeout`, `failed` (a
      job), `lane`, `merge`, `audit`, `health`, `incident` (a card naming this
      one as its cause and the check that missed it, #1946) (see
      `Slipdock.Findings.Signals`)
    * `status` – `open` until triaged: `promoted` (it became a handbook rule or
      section, said in `note`), `dismissed`, or `merged` into another finding
      (`merged_into`, which takes its count)
    * `cause` – for the system's findings, what repeats are matched on: the same
      card, source and cause adds to `count` rather than making another
    * `by` – who recorded it, in words; `user` when a person's account wrote it
    * `lesson` – the text normalised (`Slipdock.Findings.Lesson`): what repeats
      on other cards are matched on (#1941)
    * `comment_ids` – the comments that said it, so an edited or deleted
      comment takes back only its own count
    * `scope` – `board`, or `runner` for a tooling item about one machine's
      installed CLI or skills, kept with that `runner` and out of the board's
      default list
    * `cards` (virtual) – set by `Slipdock.Findings.list/2`: its own card and
      the cards of the findings merged into it
    * `proposal` – the garden proposal drafted for it once its count reached
      the board's `findings_propose_at` (#1942), with `proposed_rule` (the
      rule id it proposes) and `proposed_at_count` (its count then)
    * `waiting` (virtual) – set by `Slipdock.Findings.list/2` on an open
      finding an open proposal names: that proposal's id. It waits on the
      person deciding the proposal, not on triage (#2767)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(gotcha rule handbook-wrong tooling process)
  @sources ~w(agent rejection verification requeue timeout failed lane merge audit health incident)
  @statuses ~w(open promoted dismissed merged)
  @scopes ~w(board runner)
  @max_text_len 2000

  schema "findings" do
    field :kind, :string
    field :source, :string
    field :status, :string, default: "open"
    field :text, :string
    field :cause, :string
    field :by, :string
    field :note, :string
    field :count, :integer, default: 1
    field :lesson, :string
    field :comment_ids, {:array, :integer}, default: []
    field :scope, :string, default: "board"
    field :cards, {:array, :any}, virtual: true, default: []
    field :waiting, :integer, virtual: true

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :comment, Slipdock.Boards.Comment
    belongs_to :job, Slipdock.Runners.Job
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :runner, Slipdock.Runners.Runner
    belongs_to :proposal, Slipdock.Gardener.Suggestion
    field :proposed_rule, :string
    field :proposed_at_count, :integer
    belongs_to :merged_into, __MODULE__

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def sources, do: @sources
  def statuses, do: @statuses
  def scopes, do: @scopes

  @doc "The most a finding's text keeps."
  def max_text, do: @max_text_len

  @doc """
  A new finding. Where it came from (`board_id`, `card_id`, `comment_id`,
  `comment_ids`, `job_id`, `runner_id`, `user_id`) is set by `Slipdock.Findings`
  on the struct, never cast; `lesson` follows the text.
  """
  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [:kind, :source, :text, :cause, :by, :scope])
    |> update_change(:text, &cut/1)
    |> put_lesson()
    |> validate_required([:board_id, :kind, :source, :text])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:scope, @scopes)
    |> validate_length(:cause, max: 255)
    |> validate_length(:by, max: 255)
  end

  @doc "A status change: `status` and `note`; `merged_into` is given by `Slipdock.Findings`."
  def triage_changeset(finding, attrs, merged_into_id \\ nil) do
    finding
    |> change(merged_into_id: merged_into_id)
    |> cast(attrs, [:status, :note])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:note, max: 2000)
  end

  defp put_lesson(changeset) do
    case get_field(changeset, :text) do
      nil -> changeset
      text -> put_change(changeset, :lesson, Slipdock.Findings.Lesson.normalise(text))
    end
  end

  defp cut(nil), do: nil
  defp cut(text), do: text |> String.trim() |> String.slice(0, @max_text_len)
end
